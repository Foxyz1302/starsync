import 'package:hive_ce/hive.dart';

const connectFormBoxName = 'connect_form';

const connectKeyHost = 'host';
const connectKeyPort = 'port';
const connectKeySecret = 'secret';
const connectKeyName = 'name';
const connectKeyAvatarPath = 'avatarPath';
const connectKeyMediaPath = 'mediaPath';
const connectKeyLinkUrl = 'linkUrl';

Future<Box> openConnectFormBox() => Hive.openBox(connectFormBoxName);

Box? connectFormBoxIfOpen() =>
    Hive.isBoxOpen(connectFormBoxName) ? Hive.box(connectFormBoxName) : null;

String readString(Box box, String key, String fallback) {
  final v = box.get(key);
  return v is String ? v : fallback;
}
