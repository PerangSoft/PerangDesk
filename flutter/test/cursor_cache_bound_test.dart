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
const _max = CursorModel.kMaxDecodedCursors;
// The largest shape the core lets through, in pixels a side.
const _largest = 512;

Map<String, dynamic> _event(int id, {int size = _size}) => {
      'id': '$id',
      'hotx': '0',
      'hoty': '0',
      'width': '$size',
      'height': '$size',
      // Transparent, which keeps the JSON short and the PNG small.
      'colors': jsonEncode(List.filled(size * size * 4, 0)),
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

List<String> _ids(_FFI ffi) => ffi.cursorModel.decodedIds.toList();

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
      'keeps at most kMaxDecodedCursors cursors and re-requests an evicted one',
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

  test('the shape in use is kept however late it decodes', () async {
    final cursor = ffi.cursorModel as _Cursor;
    _select(ffi, 0);
    expect(cursor.requested, ['0']);

    // Its resend arrives among a flood of other shapes, decoded in no set
    // order, and is followed by the id the peer is on.
    final pending = _feedConcurrently(ffi, Iterable.generate(_max + 1));
    _select(ffi, 0);
    await pending;

    expect(_ids(ffi).length, _max);
    expect(_ids(ffi), contains('0'));
    expect(cursor.cache?.id, '0');
    expect(cursor.image, isNotNull);
    _select(ffi, 0);
    expect(cursor.requested, ['0'], reason: 'nothing left to ask for');
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

  test('two cursors of the largest size stay cached together', () async {
    await _feed(ffi, 0, size: _largest);
    await _feed(ffi, 1, size: _largest);
    expect(_ids(ffi), ['0', '1'],
        reason: 'switching between two large shapes would refetch each time');
  });

  test('an enlarged animated cursor cycles through its frames from the cache',
      () async {
    // The busy pointer is a ring of eighteen shapes, each sent once. Enlarged
    // to what a Windows pointer reaches at 200% scaling, each is 512 px.
    const frames = 18;
    for (var frame = 0; frame < frames; frame++) {
      await _feed(ffi, frame, size: _largest);
    }
    final cursor = ffi.cursorModel as _Cursor;
    for (var frame = 0; frame < frames; frame++) {
      _select(ffi, frame);
    }
    expect(cursor.requested, isEmpty,
        reason: 'decoding a frame again on every turn of the ring stutters '
            'the view for as long as the peer is busy');
  });

  test('largest shapes past the pixel budget are dropped before the count',
      () async {
    final fit = CursorModel.kMaxDecodedCursorBytes ~/ (_largest * _largest * 4);
    expect(fit, lessThan(_max),
        reason: 'a budget the count reaches first bounds nothing');
    for (var i = 0; i <= fit; i++) {
      await _feed(ffi, i, size: _largest);
    }
    expect(_ids(ffi).length, fit);
    expect(_ids(ffi).first, '1');
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

  test('a moved tab carries the id in use and not the shapes', () async {
    await _feed(ffi, 0);
    _select(ffi, 0);
    final carried = ffi.ffiModel.cachedPeerData.toString();
    expect(carried, isNot(contains('colors')));
    expect(CachedPeerData.fromString(carried)?.lastCursorId['id'], '0');
  });
}
