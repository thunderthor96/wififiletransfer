// pubspec.yaml dependencies needed:
/*
dependencies:
  flutter:
    sdk: flutter
  shelf: ^1.4.1
  network_info_plus: ^5.0.0
  path_provider: ^2.1.2
  permission_handler: ^11.3.0
  archive: ^3.4.10
  image_picker: ^1.0.7
  file_picker: ^5.2.5    # <<-- ADD THIS
dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0
*/

import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:archive/archive_io.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart'; // newimport 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

void main() async {
  // Initialize the splash screen
  WidgetsFlutterBinding.ensureInitialized();

  // Delay the splash screen for 1 second
  await Future.delayed(Duration(seconds: 1));

  // Keep the splash screen active until this time
  FlutterNativeSplash.remove(); // Remove splash screen after the delay

  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WiFi File Server',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: FileServerScreen(),
    );
  }
}

class FileServerScreen extends StatefulWidget {
  @override
  _FileServerScreenState createState() => _FileServerScreenState();
}

class _FileServerScreenState extends State<FileServerScreen> {
  HttpServer? _server;
  String? _serverAddress;
  bool _isServerRunning = false;
  List<File> _selectedFiles = [];
  Directory? _selectedDirectory;
  final int _port = 1234;
  final ImagePicker _picker = ImagePicker();

  // 100 GB limit in bytes
  static const int _maxTotalBytes = 100 * 1024 * 1024 * 1024; // 100 * 1024^3

  @override
  void initState() {
    super.initState();
    _requestPermissions();

  }

  Future<void> _requestPermissions() async {
    // Basic storage/media permissions
    try {
      if (Platform.isAndroid) {
        // On Android, request storage/manage external storage or media permissions depending on SDK
        await Permission.storage.request();
        await Permission.manageExternalStorage.request();
      } else if (Platform.isIOS) {
        // iOS: photos/media permission if required by image_picker; file picking is sandboxed
        await Permission.photos.request();
      }
    } catch (e) {
      print('Permission request error: $e');
    }
  }



  Future<String?> _getLocalIP() async {
    try {
      final info = NetworkInfo();
      final wifiIP = await info.getWifiIP();

      // Also try getting IP from network interfaces as backup
      if (wifiIP == null) {
        for (var interface in await NetworkInterface.list()) {
          for (var addr in interface.addresses) {
            if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
              if (addr.address.startsWith('192.168.') ||
                  addr.address.startsWith('10.') ||
                  addr.address.startsWith('172.')) {
                print('Found alternative IP: ${addr.address}');
                return addr.address;
              }
            }
          }
        }
      }

      print('WiFi IP: $wifiIP');
      return wifiIP;
    } catch (e) {
      print('Error getting WiFi IP: $e');

      // Fallback method - try to get any local network IP
      try {
        for (var interface in await NetworkInterface.list()) {
          for (var addr in interface.addresses) {
            if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
              if (addr.address.startsWith('192.168.') ||
                  addr.address.startsWith('10.') ||
                  addr.address.startsWith('172.')) {
                print('Fallback IP found: ${addr.address}');
                return addr.address;
              }
            }
          }
        }
      } catch (e2) {
        print('Fallback IP detection failed: $e2');
      }

      return null;
    }
  }

  /// New: pick ANY file types using file_picker. Enforces 100GB total limit.
  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: false,
        // allow any file type:
        type: FileType.any,
      );

      if (result == null) {
        // User canceled
        return;
      }

      // Convert selected paths into File objects
      final pickedPaths = result.paths.where((p) => p != null).map((p) => File(p!)).toList();

      // Sum sizes to check limit
      int currentTotal = await _totalSelectedSize();
      int newFilesTotal = 0;
      for (final f in pickedPaths) {
        if (await f.exists()) {
          final len = await f.length();
          newFilesTotal += len;
        } else {
          print('Picked file does not exist: ${f.path}');
        }
      }

      if (currentTotal + newFilesTotal > _maxTotalBytes) {
        final allowedLeft = _maxTotalBytes - currentTotal;
        final allowedMB = (allowedLeft / (1024 * 1024)).toStringAsFixed(1);
        _showError('Cannot add files — 100 GB total limit exceeded. Remaining: ${allowedMB} MB');
        return;
      }

      setState(() {
        // prevent duplicates by path
        for (final f in pickedPaths) {
          if (!_selectedFiles.any((sel) => sel.path == f.path)) {
            _selectedFiles.add(f);
          }
        }
      });

      _showSuccess('Added ${pickedPaths.length} file(s)');
    } catch (e) {
      _showError('Error picking files: $e');
    }
  }

  Future<int> _totalSelectedSize() async {
    int total = 0;
    for (final f in _selectedFiles) {
      try {
        if (await f.exists()) {
          total += await f.length();
        }
      } catch (e) {
        print('Error reading file size ${f.path}: $e');
      }
    }
    return total;
  }

  // Old image picker kept as optional fallback, but not used in UI per your request
  Future<void> _pickImages() async {
    try {
      final List<XFile> images = await _picker.pickMultipleMedia();

      if (images.isNotEmpty) {
        final files = images.map((xfile) => File(xfile.path)).toList();

        // size check similar to _pickFiles
        int currentTotal = await _totalSelectedSize();
        int newFilesTotal = 0;
        for (final f in files) {
          if (await f.exists()) {
            newFilesTotal += await f.length();
          }
        }

        if (currentTotal + newFilesTotal > _maxTotalBytes) {
          _showError('Cannot add media — 100 GB total limit exceeded.');
          return;
        }

        setState(() {
          _selectedFiles.addAll(files);
        });
        _showSuccess('Added ${images.length} media files');
      }
    } catch (e) {
      _showError('Error picking images: $e');
    }
  }

  Future<void> _pickFromDocuments() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final documentsDir = Directory(appDir.path);

      if (await documentsDir.exists()) {
        final files = documentsDir
            .listSync()
            .whereType<File>()
            .where((file) => !_selectedFiles.any((selected) => selected.path == file.path))
            .toList();

        if (files.isNotEmpty) {
          // check size
          int currentTotal = await _totalSelectedSize();
          int addedTotal = 0;
          for (final f in files) {
            addedTotal += await f.length();
          }
          if (currentTotal + addedTotal > _maxTotalBytes) {
            _showError('Cannot add documents — 100 GB limit would be exceeded.');
            return;
          }

          setState(() {
            _selectedFiles.addAll(files);
          });
          _showSuccess('Added ${files.length} files from Documents');
        } else {
          _showError('No new files found in Documents folder');
        }
      }
    } catch (e) {
      _showError('Error accessing documents: $e');
    }
  }

  Future<void> _pickDownloads() async {
    try {
      Directory? downloadsDir;
      if (Platform.isAndroid) {
        downloadsDir = Directory('/storage/emulated/0/Download');
      } else if (Platform.isIOS) {
        final appDir = await getApplicationDocumentsDirectory();
        downloadsDir = Directory('${appDir.path}/Downloads');
      }

      if (downloadsDir != null && await downloadsDir.exists()) {
        final files = downloadsDir
            .listSync()
            .whereType<File>()
            .where((file) => !_selectedFiles.any((selected) => selected.path == file.path))
            .take(10) // Limit to first 10 files
            .toList();

        if (files.isNotEmpty) {
          int currentTotal = await _totalSelectedSize();
          int addedTotal = 0;
          for (final f in files) {
            addedTotal += await f.length();
          }
          if (currentTotal + addedTotal > _maxTotalBytes) {
            _showError('Cannot add downloads — 100 GB limit would be exceeded.');
            return;
          }

          setState(() {
            _selectedFiles.addAll(files);
          });
          _showSuccess('Added ${files.length} files from Downloads');
        } else {
          _showError('No new files found in Downloads folder');
        }
      } else {
        _showError('Downloads folder not accessible');
      }
    } catch (e) {
      _showError('Error accessing downloads: $e');
    }
  }

  void _addCustomFile() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final customFile = File('${appDir.path}/custom_${DateTime.now().millisecondsSinceEpoch}.txt');

      await customFile.writeAsString('Custom file created at ${DateTime.now()}\n\nYou can modify this content or create your own files.');

      // size check
      int currentTotal = await _totalSelectedSize();
      final len = await customFile.length();
      if (currentTotal + len > _maxTotalBytes) {
        _showError('Cannot create file — 100 GB limit would be exceeded.');
        await customFile.delete();
        return;
      }

      setState(() {
        _selectedFiles.add(customFile);
      });
      _showSuccess('Created custom file: ${customFile.path.split('/').last}');
    } catch (e) {
      _showError('Error creating custom file: $e');
    }
  }

  void _clearFiles() {
    setState(() {
      _selectedFiles.clear();
      _selectedDirectory = null;
    });
    _showSuccess('Cleared all selected files');
  }

  Future<File> _createZipFromDirectory(Directory directory) async {
    final tempDir = await getTemporaryDirectory();
    final zipFile = File('${tempDir.path}/${directory.path.split('/').last}.zip');

    final encoder = ZipFileEncoder();
    encoder.create(zipFile.path);
    encoder.addDirectory(directory);
    encoder.close();

    return zipFile;
  }

  Future<void> _startServer() async {
    try {
      final ip = await _getLocalIP();
      if (ip == null) {
        _showError('Could not get WiFi IP address. Make sure you\'re connected to WiFi.');
        return;
      }

      final handler = _createHandler();

      // Try binding to all interfaces first, then fallback to specific IP
      try {
        _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, _port);
        print('Server started on all interfaces: 0.0.0.0:$_port');
      } catch (e) {
        print('Failed to bind to all interfaces, trying specific IP: $e');
        _server = await shelf_io.serve(handler, ip, _port);
        print('Server started on specific IP: $ip:$_port');
      }

      setState(() {
        _isServerRunning = true;
        _serverAddress = 'http://$ip:$_port';
      });

      _showSuccess('Server started at $_serverAddress\n\nIf connection fails, check:\n• Both devices on same WiFi\n• Firewall settings\n• Try IP: $ip');
    } catch (e) {
      _showError('Error starting server: $e\n\nTry:\n• Restarting WiFi\n• Using mobile hotspot\n• Checking firewall');
    }
  }

  Future<void> _stopServer() async {
    if (_server != null) {
      await _server!.close(force: true);
      setState(() {
        _isServerRunning = false;
        _serverAddress = null;
        _server = null;
      });
      _showSuccess('Server stopped');
    }
  }

  Handler _createHandler() {
    return (Request request) async {
      final path = request.url.path;

      // Add CORS headers for browser compatibility
      final headers = {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type',
        'Cache-Control': 'no-cache, no-store, must-revalidate',
        'Pragma': 'no-cache',
        'Expires': '0',
      };

      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: headers);
      }

      if (path == '' || path == '/') {
        return _handleHomePage(headers);
      } else if (path == 'download-files') {
        return await _handleFilesDownload(headers);
      } else if (path == 'download-folder') {
        return await _handleFolderDownload(headers);
      } else if (path.startsWith('file/')) {
        return await _handleSingleFileDownload(path, headers);
      }

      return Response.notFound('Not found', headers: headers);
    };
  }

  Response _handleHomePage(Map<String, String> headers) {
    final html = '''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>📱 WiFi File Server</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(45deg, #0055a0, #0055a0);
            min-height: 100vh;
            padding: 20px;
        }
        .container {
            max-width: 800px;
            margin: 0 auto;
            background: rgba(255, 255, 255, 0.95);
            backdrop-filter: blur(10px);
            border-radius: 20px;
            padding: 30px;
            box-shadow: 0 20px 40px rgba(0,0,0,0.1);
        }
        h1 {
            text-align: center;
            color: #333;
            margin-bottom: 30px;
            font-size: 2.5em;
            text-shadow: 2px 2px 4px rgba(0,0,0,0.1);
        }
        .status-card {
            background: linear-gradient(45deg, #4CAF50, #45a049);
            color: white;
            padding: 20px;
            border-radius: 15px;
            margin-bottom: 30px;
            text-align: center;
        }
        .button {
            display: inline-block;
            padding: 15px 30px;
            margin: 10px;
            background: linear-gradient(45deg, #2196F3, #21CBF3);
            color: white;
            text-decoration: none;
            border-radius: 25px;
            font-size: 16px;
            font-weight: bold;
            transition: all 0.3s ease;
            box-shadow: 0 4px 15px rgba(33, 150, 243, 0.3);
            min-width: 200px;
            text-align: center;
        }
        .button:hover {
            transform: translateY(-2px);
            box-shadow: 0 8px 25px rgba(33, 150, 243, 0.4);
        }
        .button.download {
            background: linear-gradient(45deg, #0055a0, #0055a0);
            box-shadow: 0 4px 15px rgba(255, 107, 107, 0.3);
        }
        .button.download:hover {
            box-shadow: 0 8px 25px rgba(255, 107, 107, 0.4);
        }
        .file-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
            gap: 15px;
            margin: 20px 0;
        }
        .file-card {
            background: white;
            border-radius: 10px;
            padding: 15px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
            transition: transform 0.2s ease;
        }
        .file-card:hover {
            transform: translateY(-2px);
        }
        .file-name {
            font-weight: bold;
            color: #333;
            margin-bottom: 5px;
        }
        .file-size {
            font-size: 12px;
            color: #666;
            margin-bottom: 10px;
        }
        .download-link {
            color: #2196F3;
            text-decoration: none;
            font-weight: bold;
        }
        .download-link:hover {
            text-decoration: underline;
        }
        .info-banner {
            background: linear-gradient(45deg, #FFC107, #FF9800);
            color: white;
            padding: 15px;
            border-radius: 10px;
            margin: 20px 0;
            text-align: center;
        }
        .stats {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
            gap: 15px;
            margin: 20px 0;
        }
        .stat-card {
            background: linear-gradient(45deg, #0055a0, #0055a0);
            color: white;
            padding: 15px;
            border-radius: 10px;
            text-align: center;
        }
        .stat-number {
            font-size: 2em;
            font-weight: bold;
        }
        .stat-label {
            font-size: 0.9em;
            opacity: 0.9;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>WiFi File Server</h1>
        
        <div class="status-card">
            <h2>Server Online</h2>
            <p>Ready to share files across your local network</p>
        </div>
        
        <div class="stats">
            <div class="stat-card">
                <div class="stat-number">${_selectedFiles.length}</div>
                <div class="stat-label">Files Available</div>
            </div>
            <div class="stat-card">
                <div class="stat-number">${_selectedDirectory != null ? '1' : '0'}</div>
                <div class="stat-label">Folders</div>
            </div>
        </div>
        
        ${_selectedFiles.isNotEmpty ? '''
        <div style="text-align: center; margin: 30px 0;">
            <a href="/download-files" class="button download">Download All Files (ZIP)</a>
        </div>
        
        <div class="file-grid">
            ${_selectedFiles.map((file) {
      final fileName = file.path.split('/').last;
      final fileSize = file.existsSync() ? file.lengthSync() : 0;
      final sizeStr = fileSize < 1024 ? '${fileSize}B' :
      fileSize < 1024 * 1024 ? '${(fileSize / 1024).toStringAsFixed(1)}KB' :
      '${(fileSize / (1024 * 1024)).toStringAsFixed(1)}MB';
      return '''
                <div class="file-card">
                    <div class="file-name">📄 $fileName</div>
                    <div class="file-size">Size: $sizeStr</div>
                    <a href="/file/${Uri.encodeComponent(fileName)}" class="download-link">Download</a>
                </div>
              ''';
    }).join('')}
        </div>
        ''' : ''}
        
        ${_selectedDirectory != null ? '''
        <div style="text-align: center; margin: 30px 0;">
            <a href="/download-folder" class="button download">Download Folder (ZIP)</a>
        </div>
        ''' : ''}
        
        ${_selectedFiles.isEmpty && _selectedDirectory == null ? '''
        <div class="info-banner">
            📭 No files selected yet<br>
            <small>Select files in the mobile app to start sharing</small>
        </div>
        ''' : ''}
        
        <div style="text-align: center; margin-top: 30px; padding-top: 20px; border-top: 2px solid #eee;">
            <p style="color: #666; font-size: 14px;">
                 Connected via WiFi • Refresh page for updates
            </p>
        </div>
    </div>
</body>
</html>
    ''';

    return Response.ok(html, headers: {...headers, 'Content-Type': 'text/html'});
  }

  Future<Response> _handleFilesDownload(Map<String, String> headers) async {
    if (_selectedFiles.isEmpty) {
      return Response.notFound('No files selected', headers: headers);
    }

    try {
      final tempDir = await getTemporaryDirectory();
      final zipFile = File('${tempDir.path}/files_${DateTime.now().millisecondsSinceEpoch}.zip');

      final encoder = ZipFileEncoder();
      encoder.create(zipFile.path);

      for (final file in _selectedFiles) {
        if (await file.exists()) {
          encoder.addFile(file);
        }
      }
      encoder.close();

      final bytes = await zipFile.readAsBytes();
      return Response.ok(
        bytes,
        headers: {
          ...headers,
          'Content-Type': 'application/zip',
          'Content-Disposition': 'attachment; filename="files.zip"',
          'Content-Length': bytes.length.toString(),
        },
      );
    } catch (e) {
      return Response.internalServerError(body: 'Error creating zip: $e', headers: headers);
    }
  }

  Future<Response> _handleFolderDownload(Map<String, String> headers) async {
    if (_selectedDirectory == null) {
      return Response.notFound('No folder selected', headers: headers);
    }

    try {
      final zipFile = await _createZipFromDirectory(_selectedDirectory!);
      final bytes = await zipFile.readAsBytes();

      return Response.ok(
        bytes,
        headers: {
          ...headers,
          'Content-Type': 'application/zip',
          'Content-Disposition': 'attachment; filename="${_selectedDirectory!.path.split('/').last}.zip"',
          'Content-Length': bytes.length.toString(),
        },
      );
    } catch (e) {
      return Response.internalServerError(body: 'Error creating folder zip: $e', headers: headers);
    }
  }

  Future<Response> _handleSingleFileDownload(String path, Map<String, String> headers) async {
    final fileName = Uri.decodeComponent(path.substring(5)); // Remove 'file/' prefix

    try {
      final file = _selectedFiles.firstWhere(
            (f) => f.path.split('/').last == fileName,
        orElse: () => throw Exception('File not found'),
      );

      if (!await file.exists()) {
        return Response.notFound('File not found', headers: headers);
      }

      // Stream file to avoid large memory usage
      final stream = file.openRead();
      final mimeType = _getMimeType(fileName);

      return Response.ok(
        stream,
        headers: {
          ...headers,
          'Content-Type': mimeType,
          'Content-Disposition': 'attachment; filename="$fileName"',
        },
      );
    } catch (e) {
      return Response.notFound('File not found: $e', headers: headers);
    }
  }

  String _getMimeType(String fileName) {
    final extension = fileName.split('.').last.toLowerCase();
    switch (extension) {
      case 'pdf':
        return 'application/pdf';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'txt':
        return 'text/plain';
      case 'json':
        return 'application/json';
      case 'zip':
        return 'application/zip';
      case 'mp4':
        return 'video/mp4';
      case 'mp3':
        return 'audio/mpeg';
      default:
        return 'application/octet-stream';
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: Duration(seconds: 6),
      ),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 5),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _testConnection() async {
    if (!_isServerRunning || _serverAddress == null) {
      _showError('Server is not running');
      return;
    }

    try {
      final client = HttpClient();
      client.connectionTimeout = Duration(seconds: 5);

      final uri = Uri.parse(_serverAddress!);
      final request = await client.getUrl(uri);
      final response = await request.close();

      if (response.statusCode == 200) {
        _showSuccess('Server is reachable!\nStatus: ${response.statusCode}');
      } else {
        _showError('Server responded with status: ${response.statusCode}');
      }

      client.close();
    } catch (e) {
      _showError('Connection test failed: $e\n\nTroubleshooting:\n• Check if both devices are on same WiFi\n• Try disabling VPN\n• Check firewall settings');
    }
  }

  Future<void> _showNetworkInfo() async {
    try {
      final interfaces = await NetworkInterface.list();
      final info = NetworkInfo();
      final wifiName = await info.getWifiName();
      final wifiBSSID = await info.getWifiBSSID();

      String interfaceInfo = '';
      for (var interface in interfaces) {
        if (interface.addresses.isNotEmpty) {
          interfaceInfo += '${interface.name}:\n';
          for (var addr in interface.addresses) {
            if (addr.type == InternetAddressType.IPv4) {
              interfaceInfo += '  ${addr.address}\n';
            }
          }
        }
      }

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Network Information'),
          content: SingleChildScrollView(
            child: Text(
              'WiFi Network: ${wifiName ?? 'Unknown'}\n'
                  'BSSID: ${wifiBSSID ?? 'Unknown'}\n'
                  'Server: $_serverAddress\n\n'
                  'Network Interfaces:\n$interfaceInfo\n'
                  'Troubleshooting Tips:\n'
                  '• Both devices must be on same WiFi\n'
                  '• Disable VPN if active\n'
                  '• Check router firewall settings\n                  • Try mobile hotspot as test\n                  • Some networks block device-to-device communication',
              style: TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      _showError('Error getting network info: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('WiFi File Server'),
        backgroundColor: Colors.blue,
        elevation: 0,
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.blue, Colors.blue],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Server Status Card
                Card(
                  elevation: 8,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(15),
                      gradient: LinearGradient(
                        colors: _isServerRunning ? [Colors.green, Colors.green.shade700] : [Colors.red, Colors.red.shade700],
                      ),
                    ),
                    child: Padding(
                      padding: EdgeInsets.all(20.0),
                      child: Column(
                        children: [
                          Icon(
                            _isServerRunning ? Icons.cloud_done : Icons.cloud_off,
                            size: 40,
                            color: Colors.white,
                          ),
                          SizedBox(height: 10),
                          Text(
                            _isServerRunning ? 'Server Running' : 'Server Stopped',
                            style: TextStyle(
                              fontSize: 20,
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (_serverAddress != null) ...[
                            SizedBox(height: 10),
                            Container(
                              padding: EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.black26,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: SelectableText(
                                _serverAddress!,
                                style: TextStyle(
                                  fontSize: 16,
                                  color: Colors.white,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                            SizedBox(height: 5),
                            Text(
                              'Open this URL in any browser on the same WiFi',
                              style: TextStyle(fontSize: 12, color: Colors.white70),
                            ),
                            SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                ElevatedButton.icon(
                                  onPressed: _testConnection,
                                  icon: Icon(Icons.network_check, size: 16),
                                  label: Text('Test', style: TextStyle(fontSize: 12)),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.blue,
                                    foregroundColor: Colors.white,
                                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  ),
                                ),
                                ElevatedButton.icon(
                                  onPressed: _showNetworkInfo,
                                  icon: Icon(Icons.info, size: 16),
                                  label: Text('Info', style: TextStyle(fontSize: 12)),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.orange,
                                    foregroundColor: Colors.white,
                                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),

                SizedBox(height: 20),

                // File Management Section
                Expanded(
                  child: Card(
                    elevation: 8,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                    child: Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '📁 File Management',
                            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: 16),

                          // Only one button now: File (formerly Media)
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: _pickFiles,
                                  icon: Icon(Icons.insert_drive_file),
                                  label: Text('File'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.orange,
                                    foregroundColor: Colors.white,
                                    padding: EdgeInsets.all(12),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                ),
                              ),
                            ],
                          ),

                          SizedBox(height: 16),

                          // Selected files display
                          if (_selectedFiles.isNotEmpty) ...[
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                FutureBuilder<int>(
                                  future: _totalSelectedSize(),
                                  builder: (context, snapshot) {
                                    final totalBytes = snapshot.data ?? 0;
                                    final totalMB = (totalBytes / (1024 * 1024)).toStringAsFixed(1);
                                    return Text(
                                      'Selected Files: ${_selectedFiles.length} • ${totalMB} MB used',
                                      style: Theme.of(context).textTheme.titleMedium,
                                    );
                                  },
                                ),
                                TextButton(
                                  onPressed: _clearFiles,
                                  child: Text('Clear All'),
                                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                                ),
                              ],
                            ),
                            SizedBox(height: 10),
                            Expanded(
                              child: ListView.builder(
                                itemCount: _selectedFiles.length,
                                itemBuilder: (context, index) {
                                  final file = _selectedFiles[index];
                                  final fileName = file.path.split('/').last;
                                  return Card(
                                    margin: EdgeInsets.only(bottom: 8),
                                    child: ListTile(
                                      leading: Icon(_getFileIcon(fileName)),
                                      title: Text(fileName, style: TextStyle(fontSize: 14)),
                                      subtitle: Text(file.path, style: TextStyle(fontSize: 10, color: Colors.grey)),
                                      trailing: IconButton(
                                        icon: Icon(Icons.close, color: Colors.red),
                                        onPressed: () {
                                          setState(() {
                                            _selectedFiles.removeAt(index);
                                          });
                                        },
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ] else ...[
                            Expanded(
                              child: Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.folder_open, size: 64, color: Colors.grey),
                                    SizedBox(height: 16),
                                    Text(
                                      'No files selected',
                                      style: TextStyle(fontSize: 18, color: Colors.grey),
                                    ),
                                    SizedBox(height: 8),
                                    Text(
                                      'Choose files to share over WiFi (max total 100 GB)',
                                      style: TextStyle(fontSize: 14, color: Colors.grey),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),

                SizedBox(height: 20),

                // Server control button
                ElevatedButton.icon(
                  onPressed: _isServerRunning ? _stopServer : _startServer,
                  icon: Icon(_isServerRunning ? Icons.stop : Icons.play_arrow, size: 28),
                  label: Text(
                    _isServerRunning ? 'Stop Server' : 'Start Server',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isServerRunning ? Colors.red : Colors.green,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(vertical: 16, horizontal: 24),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 4,
                  ),
                ),

                SizedBox(height: 16),

                // Instructions card
                Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.info_outline, color: Colors.blue),
                            SizedBox(width: 8),
                            Text(
                              'How to Use:',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.blue,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 12),
                        _buildInstructionStep('1', 'Tap "File" to select files (any type)'),
                        _buildInstructionStep('2', 'Start the server'),
                        _buildInstructionStep('3', 'Connect other devices to the same WiFi'),
                        _buildInstructionStep('4', 'Open the server URL in any browser'),
                        _buildInstructionStep('5', 'Download files or folders as ZIP'),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInstructionStep(String number, String instruction) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: Colors.blue,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                number,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              instruction,
              style: TextStyle(fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  IconData _getFileIcon(String fileName) {
    final extension = fileName.split('.').last.toLowerCase();
    switch (extension) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
        return Icons.image;
      case 'mp4':
      case 'mov':
      case 'avi':
        return Icons.video_file;
      case 'mp3':
      case 'wav':
      case 'aac':
        return Icons.audio_file;
      case 'txt':
      case 'md':
        return Icons.text_snippet;
      case 'json':
      case 'xml':
        return Icons.code;
      case 'zip':
      case 'rar':
        return Icons.archive;
      default:
        return Icons.insert_drive_file;
    }
  }

  @override
  void dispose() {
    _stopServer();
    super.dispose();
  }
}
