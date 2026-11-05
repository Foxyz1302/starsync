import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:starsync/src/platform/crash_watch.dart';

// `wevtutil qe Application /q:... /f:xml` output: events back to back, no
// root element; Windows 10+ names the 1000 Data fields, 1001 never does.
const _sample = '''
<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'><System><Provider Name='Application Error'/><EventID Qualifiers='0'>1000</EventID><Version>0</Version><Level>2</Level><Task>100</Task><Opcode>0</Opcode><Keywords>0x80000000000000</Keywords><TimeCreated SystemTime='2026-11-04T19:21:07.4471160Z'/><EventRecordID>51234</EventRecordID><Correlation/><Execution ProcessID='0' ThreadID='0'/><Channel>Application</Channel><Computer>DESKTOP-ABC</Computer><Security/></System><EventData><Data Name='AppName'>starsync.exe</Data><Data Name='AppVersion'>1.4.0.0</Data><Data Name='AppTimeStamp'>6720a1b2</Data><Data Name='ModuleName'>libmpv-2.dll</Data><Data Name='ModuleVersion'>0.0.0.0</Data><Data Name='ModuleTimeStamp'>00000000</Data><Data Name='ExceptionCode'>c0000005</Data><Data Name='FaultingOffset'>00000000001a2b3c</Data><Data Name='ProcessId'>0x1a2c</Data><Data Name='ProcessCreationTime'>0x1db2ef0c9a3b1d2</Data><Data Name='AppPath'>C:\\Users\\someone\\AppData\\Local\\Starsync\\starsync.exe</Data><Data Name='ModulePath'>C:\\Users\\someone\\AppData\\Local\\Starsync\\libmpv-2.dll</Data><Data Name='IntegratorReportId'>0d6b1d6e-1111-2222-3333-444455556666</Data><Data Name='PackageFullName'></Data><Data Name='PackageRelativeAppId'/></EventData><RenderingInfo Culture='de-DE'><Message>Name der fehlerhaften Anwendung: starsync.exe</Message></RenderingInfo></Event><Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'><System><Provider Name='Windows Error Reporting'/><EventID Qualifiers='0'>1001</EventID><TimeCreated SystemTime='2026-11-04T19:21:09.1000000Z'/></System><EventData><Data>1953182337</Data><Data>4</Data><Data>APPCRASH</Data><Data>Nicht verf&#252;gbar</Data><Data>0</Data><Data>starsync.exe</Data><Data>1.4.0.0</Data><Data>6720a1b2</Data><Data>libmpv-2.dll</Data><Data>0.0.0.0</Data><Data>00000000</Data><Data>c0000005</Data><Data>00000000001a2b3c</Data><Data></Data><Data></Data></EventData></Event>
<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'><System><EventID Qualifiers='0'>1000</EventID><TimeCreated SystemTime='2026-11-04T10:00:00.0000000Z'/></System><EventData><Data Name='AppName'>OtherApp.exe</Data><Data Name='AppVersion'>2.0</Data></EventData></Event>
<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'><System><EventID Qualifiers='0'>1002</EventID><TimeCreated SystemTime='2026-11-03T08:00:00.0000000Z'/></System><EventData><Data>Starsync.exe</Data><Data>1.3.2.0</Data><Data>2f30</Data><Data>01db2e0000000000</Data><Data>4294967295</Data><Data>C:\\Users\\someone\\starsync.exe</Data><Data>abcd</Data><Data></Data><Data></Data><Data>Unknown</Data></EventData></Event>
''';

void main() {
  test('only the app\'s crash and hang records, from the unlocalized event data, no paths', () {
    final got = parseWindowsCrashes(_sample);
    expect(got.length, 3);
    expect(got[0].id, 1000);
    expect(got[0].time, '2026-11-04T19:21:07.4471160Z');
    expect(got[0].fields, {
      'version': '1.4.0.0',
      'module': 'libmpv-2.dll',
      'moduleVersion': '0.0.0.0',
      'exception': 'c0000005',
      'offset': '00000000001a2b3c',
    });
    expect(got[1].fields, {
      'event': 'APPCRASH',
      'version': '1.4.0.0',
      'module': 'libmpv-2.dll',
      'exception': 'c0000005',
      'offset': '00000000001a2b3c',
    });
    expect(got[2].fields, {'version': '1.3.2.0', 'hangType': 'Unknown'});
    expect('$got', isNot(contains('someone')));
    expect('${got[0]}',
        'crash (1000) at 2026-11-04T19:21:07.4471160Z version=1.4.0.0 module=libmpv-2.dll moduleVersion=0.0.0.0 exception=c0000005 offset=00000000001a2b3c');
  });

  test('junk or nothing parses to nothing', () {
    expect(parseWindowsCrashes(''), isEmpty);
    expect(parseWindowsCrashes('Fehler: Zugriff verweigert'), isEmpty);
  });

  test('the marker: a start after an unclean end finds it, a clean close removes it', () {
    final dir = Directory.systemTemp.createTempSync('crash_watch');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/running.json');
    startCrashWatch(dir.path, version: '1.4.1');
    expect(jsonDecode(f.readAsStringSync())['version'], '1.4.1');
    crashWatchClosing();
    expect(jsonDecode(f.readAsStringSync())['closing'], isNotNull);
    crashWatchClean();
    expect(jsonDecode(f.readAsStringSync())['quit'], isNotNull, reason: 'kept: a teardown crash shows after it');
    // The next start after a finished close does not call it unclean.
    startCrashWatch(dir.path, version: '1.4.2');
    final j = jsonDecode(f.readAsStringSync());
    expect([j['version'], j['quit'], j['closing']], ['1.4.2', null, null]);
  });

  test('the 1.2.x name counts as the app', () {
    final got = parseWindowsCrashes(_sample.replaceAll('starsync.exe', 'watch_together.exe'));
    expect(got.length, 3);
  });
}
