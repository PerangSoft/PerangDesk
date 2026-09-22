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

/// A shape arriving as the core delivers it: its pixels as they are.
Future<void> _feed(_FFI ffi, int id, {int size = _size}) => ffi.ffiModel
    .handleCursorData('$id', 0, 0, size, size, Uint8List(size * size * 4));

/// Dispatches every shape the way the session loop does, without awaiting one
/// before starting the next.
Future<void> _feedConcurrently(_FFI ffi, Iterable<int> ids) =>
    Future.wait(ids.map((id) => _feed(ffi, id)));

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
    final inFlight = _feed(ffi, 0);
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

  test('shapes of the largest size are decoded like any other', () async {
    await _feed(ffi, 0, size: _largest);
    await _feed(ffi, 1, size: _largest);
    expect(_ids(ffi), ['0', '1']);
    expect(ffi.cursorModel.image, isNotNull);
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
    expect(ffi.cursorModel.id, '2');
  });

  test('a moved tab carries the id in use and not the shapes', () async {
    await _feed(ffi, 0);
    _select(ffi, 0);
    final carried = ffi.ffiModel.cachedPeerData.toString();
    expect(carried, isNot(contains('colors')));
    expect(CachedPeerData.fromString(carried)?.lastCursorId['id'], '0');
  });
}
