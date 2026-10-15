import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../../files/scanner.dart';
import '../ports/folder_access.dart';
import '../ports/url_opener.dart';

/// [FolderAccess] on a desktop file system: file_picker's dialogs, the
/// [scanFolder] walk, the file manager through [UrlOpener].
class DesktopFolders implements FolderAccess {
  final UrlOpener urls;
  const DesktopFolders(this.urls);

  @override
  Future<String?> pickFolder({required String dialogTitle}) => FilePicker.getDirectoryPath(dialogTitle: dialogTitle);

  @override
  Future<List<String>> pickFiles({required String dialogTitle, required List<String> extensions}) async {
    final files = await FilePicker.pickFiles(
      dialogTitle: dialogTitle,
      type: FileType.custom,
      allowedExtensions: extensions,
    );
    return [for (final f in files) ?f.path];
  }

  @override
  Future<FolderScan> scan(String dir) => scanFolder(dir);

  @override
  bool folderExists(String dir) => Directory(dir).existsSync();

  @override
  Future<FileStat> stat(String path) => File(path).stat();

  // The file manager opens a folder path the way a browser opens a link.
  @override
  Future<bool> reveal(String dir) => urls.open(Uri.directory(dir).toString());
}
