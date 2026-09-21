import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/native/custom_cursor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

class _Cursor extends CursorModel {
  _Cursor(FFI ffi) : super(WeakReference(ffi));
  final requested = <String>[];
  @override
  requestCursorData(String id) => requested.add(id);
}

class _FFI extends Fake implements FFI {
  _FFI() {
    ffiModel = FfiModel(WeakReference(this));
    cursorModel = _Cursor(this);
  }
  @override
  final SessionID sessionId = const Uuid().v4obj();
  @override
  late final FfiModel ffiModel;
  @override
  late final CursorModel cursorModel;
}

const _size = 8;
const _max = CachedPeerData.kMaxCursorDataCount;

Map<String, dynamic> _event(int id, {int size = _size}) => {
      'id': '$id',
      'hotx': '0',
      'hoty': '0',
      'width': '$size',
      'height': '$size',
      'colors': jsonEncode(List.filled(size * size * 4, 255)),
    };

/// Mirrors the `cursor_data` branch of the session event listener.
Future<void> _feed(_FFI ffi, int id, {int size = _size}) async {
  final evt = _event(id, size: size);
  ffi.ffiModel.updateLastCursorId(evt);
  await ffi.ffiModel.handleCursorData(evt);
}

/// Dispatches every event the way the session loop does, without awaiting one
/// before starting the next.
Future<void> _feedConcurrently(_FFI ffi, Iterable<int> ids) {
  final pending = <Future<void>>[];
  for (final id in ids) {
    final evt = _event(id);
    ffi.ffiModel.updateLastCursorId(evt);
    pending.add(ffi.ffiModel.handleCursorData(evt));
  }
  return Future.wait(pending);
}

/// Mirrors the `cursor_id` branch of the session event listener.
void _select(_FFI ffi, int id) {
  final evt = {'id': '$id'};
  ffi.ffiModel.updateLastCursorId(evt);
  ffi.ffiModel.handleCursorId(evt);
}

List<String> _ids(_FFI ffi) => ffi.ffiModel.cachedPeerData.cursorDataList
    .map((e) => e['id'] as String)
    .toList();

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final channel = Platform.isWindows
      ? SystemChannels.mouseCursor
      : const MethodChannel('flutter_custom_cursor');
  final deleted = <String>[];
  late _FFI ffi;
  setUp(() {
    deleted.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      final args = call.arguments as Map<dynamic, dynamic>;
      if (call.method.startsWith('deleteCustomCursor')) {
        deleted.add(args['name'] as String);
      }
      return call.method.startsWith('createCustomCursor') ? args['name'] : null;
    });
    ffi = _FFI();
  });
  tearDown(() {
    ffi.cursorModel.disposeImages();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test(
      'keeps at most kMaxCursorDataCount cursors and re-requests an evicted one',
      () async {
    for (var i = 0; i <= _max; i++) {
      await _feed(ffi, i);
    }
    expect(_ids(ffi).length, _max);
    expect(_ids(ffi).first, '1');
    final cursor = ffi.cursorModel as _Cursor;
    _select(ffi, 1);
    expect(cursor.requested, isEmpty);
    _select(ffi, 0);
    expect(cursor.requested, ['0']);
  });

  test('an evicted cursor is requested once while its data is in flight',
      () async {
    for (var i = 0; i <= _max; i++) {
      await _feed(ffi, i);
    }
    final cursor = ffi.cursorModel as _Cursor;
    _select(ffi, 0);
    _select(ffi, 0);
    expect(cursor.requested, ['0']);

    await _feed(ffi, 0);
    _select(ffi, 0);
    expect(cursor.requested, ['0'], reason: 'the shape is cached again');
  });

  test('a cursor selected by id is not the next one evicted', () async {
    for (var i = 0; i < _max; i++) {
      await _feed(ffi, i);
    }
    _select(ffi, 0);
    await _feed(ffi, _max);
    expect(_ids(ffi).first, '2');
    expect(_ids(ffi).last, '$_max');
    final cursor = ffi.cursorModel as _Cursor;
    _select(ffi, 0);
    expect(cursor.requested, isEmpty);
    _select(ffi, 1);
    expect(cursor.requested, ['1']);
  });

  test('eviction never leaves the painted image disposed', () async {
    final cursor = ffi.cursorModel;
    await _feed(ffi, 0);
    expect(cursor.image, isNotNull);

    cursor.removeCursor('0');
    expect(cursor.image?.debugDisposed, isNot(true));
  });

  test('a cursor is requested once while its data is still decoding', () async {
    for (var i = 0; i <= _max; i++) {
      await _feed(ffi, i);
    }
    final cursor = ffi.cursorModel as _Cursor;
    _select(ffi, 0);
    final inFlight = ffi.ffiModel.handleCursorData(_event(0));
    _select(ffi, 0);
    await inFlight;
    expect(cursor.requested, ['0']);
  });

  test('a cursor evicted while decoding is not left behind', () async {
    await _feedConcurrently(ffi, Iterable.generate(_max + 1));
    expect(_ids(ffi), isNot(contains('0')));

    final cursor = ffi.cursorModel as _Cursor;
    _select(ffi, 0);
    expect(cursor.requested, ['0'], reason: 'the late decode was kept');
  });

  test('a session clear forgets the requests it was waiting on', () async {
    for (var i = 0; i <= _max; i++) {
      await _feed(ffi, i);
    }
    final cursor = ffi.cursorModel as _Cursor;
    _select(ffi, 0);
    cursor.clear();
    _select(ffi, 0);
    expect(cursor.requested, ['0', '0']);
  });

  test('cursors far past the byte budget are dropped before the count',
      () async {
    await _feed(ffi, 0, size: 512);
    await _feed(ffi, 1, size: 512);
    expect(_ids(ffi), ['1']);
  });

  test('removing the current cursor drops its raster and notifies', () async {
    final cursor = ffi.cursorModel;
    await _feed(ffi, 0);
    _select(ffi, 0);
    expect(cursor.cache?.id, '0');
    var notified = 0;
    cursor.addListener(() => notified++);

    cursor.removeCursor('0');
    expect(cursor.cache, isNull, reason: 'the page would rebuild it natively');
    expect(notified, greaterThan(0));
  });

  test('a flood of unknown cursor ids does not grow the request set for ever',
      () async {
    final cursor = ffi.cursorModel as _Cursor;
    for (var id = 1000; id < 1000 + _max; id++) {
      _select(ffi, id);
    }
    _select(ffi, 1000 + _max);
    _select(ffi, 1000);
    expect(cursor.requested.where((id) => id == '1000').length, 2,
        reason: 'the set was never released');
  });

  test('one native registration per raster whatever the exact scale', () async {
    final cursor = ffi.cursorModel;
    cursor.peerId = 'peer';
    await _feed(ffi, 0, size: 64);
    _select(ffi, 0);
    buildCursorOfCache(cursor, 0.5 - 3e-8, cursor.cache);
    buildCursorOfCache(cursor, 0.5 - 2e-8, cursor.cache);
    await Future<void>.delayed(Duration.zero);
    expect(cursor.cachedKeys.length, 1);
  });

  test('the last selected cursor follows cursor_data as well', () async {
    await _feed(ffi, 0);
    await _feed(ffi, 1);
    _select(ffi, 0);
    await _feed(ffi, 2);
    expect(ffi.ffiModel.cachedPeerData.lastCursorId['id'], '2');
  });

  test('a tab evicting a shape leaves a sibling tab of the same peer alone',
      () async {
    final other = _FFI();
    addTearDown(other.cursorModel.disposeImages);
    for (final f in [ffi, other]) {
      f.cursorModel.peerId = 'peer';
      await _feed(f, 0);
      _select(f, 0);
      buildCursorOfCache(f.cursorModel, 1.0, f.cursorModel.cache);
    }
    await Future<void>.delayed(Duration.zero);
    final otherKey = other.cursorModel.cachedKeys.single;

    ffi.cursorModel.removeCursor('0');
    expect(deleted, isNot(contains(otherKey)));
  });

  test('clearing the session forgets its native registrations too', () async {
    final cursor = ffi.cursorModel;
    await _feed(ffi, 0);
    _select(ffi, 0);
    buildCursorOfCache(cursor, 1.0, cursor.cache);
    await Future<void>.delayed(Duration.zero);
    expect(cursor.cachedKeys, isNotEmpty);

    cursor.clear();
    expect(cursor.cachedKeys, isEmpty);
  });

  test('a shape whose resend fails to decode can be asked for again', () async {
    for (var i = 0; i <= _max; i++) {
      await _feed(ffi, i);
    }
    final cursor = ffi.cursorModel as _Cursor;
    _select(ffi, 0);
    final broken = _event(0)..['colors'] = jsonEncode(List.filled(4, 255));
    ffi.ffiModel.updateLastCursorId(broken);
    await ffi.ffiModel.handleCursorData(broken);

    _select(ffi, 0);
    expect(cursor.requested, ['0', '0']);
  });

  test('evicting a cursor deletes every native registration of it', () async {
    final cursor = ffi.cursorModel;
    cursor.peerId = 'peer';
    await _feed(ffi, 0);
    _select(ffi, 0);
    buildCursorOfCache(cursor, 1.0, cursor.cache);
    buildCursorOfCache(cursor, 0.5, cursor.cache);
    await Future<void>.delayed(Duration.zero);
    final keys = cursor.cachedKeys.toList();
    expect(keys.length, 2);
    expect(keys.every((k) => k.startsWith('peer_${ffi.sessionId}_0_')), isTrue);
    for (var i = 1; i <= _max; i++) {
      await _feed(ffi, i);
    }
    expect(_ids(ffi), isNot(contains('0')));
    expect(deleted.toSet(), keys.toSet());
    expect(cursor.cachedKeys, isEmpty);
  });
}
