import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    debugPrint("Error: Could not load .env file. Ensure it is in the root folder.");
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: const FoodLabelScreen(),
    );
  }
}

class FoodLabelScreen extends StatefulWidget {
  const FoodLabelScreen({super.key});
  @override
  State<FoodLabelScreen> createState() => _FoodLabelScreenState();
}

class _FoodLabelScreenState extends State<FoodLabelScreen> {
  File? _selectedImage;
  String _result = '';
  bool _isLoading = false;
  final ImagePicker _picker = ImagePicker();

  Future<void> _pickImage(ImageSource source) async {
    final XFile? file = await _picker.pickImage(source: source);
    if (file != null) {
      setState(() {
        _selectedImage = File(file.path);
        _result = '';
      });
      await _analyzeLabel();
    }
  }

  Future<void> _analyzeLabel() async {
    if (_selectedImage == null) return;
    
    // 1. Pull the key from your .env file
    final String apiKey = dotenv.env['GEMINI_API_KEY'] ?? '';
    if (apiKey.isEmpty) {
      setState(() => _result = 'Error: API Key is missing in your .env file.');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final imageBytes = await _selectedImage!.readAsBytes();
      final base64Image = base64Encode(imageBytes);

      const prompt = '''
Analyze this image. If it is a food label, provide:
1. Product Name
2. Ingredients (explain any complex additives like E-codes)
3. Health Rating (Healthy / Moderate / Unhealthy)
If it is NOT food (like a pen or tool), just identify what it is.
''';

      // 🛠️ UPDATED FOR 2026: Use gemini-2.5-flash (Stable)
      final url = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$apiKey'
      );

      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'contents': [
            {
              'parts': [
                {'text': prompt},
                {
                  'inline_data': {
                    'mime_type': 'image/jpeg',
                    'data': base64Image,
                  }
                }
              ]
            }
          ]
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final text = data['candidates'][0]['content']['parts'][0]['text'];
        setState(() {
          _result = text;
          _isLoading = false;
        });
      } else {
        setState(() {
          _result = 'Error ${response.statusCode}: ${response.body}';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _result = 'System Error: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🥫 Food Label AI'), 
        backgroundColor: Colors.green, 
        foregroundColor: Colors.white
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Image Preview Area
            Container(
              height: 280,
              decoration: BoxDecoration(
                color: Colors.grey[200],
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: Colors.green.shade200),
              ),
              child: _selectedImage != null 
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Image.file(_selectedImage!, fit: BoxFit.cover)
                  ) 
                : const Icon(Icons.camera_alt, size: 50, color: Colors.grey),
            ),
            const SizedBox(height: 20),
            
            // Buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isLoading ? null : () => _pickImage(ImageSource.camera), 
                    icon: const Icon(Icons.camera),
                    label: const Text('Camera'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isLoading ? null : () => _pickImage(ImageSource.gallery), 
                    icon: const Icon(Icons.photo),
                    label: const Text('Gallery'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 25),
            
            // Loading and Result Area
            if (_isLoading) 
              const Center(
                child: Column(
                  children: [
                    CircularProgressIndicator(color: Colors.green),
                    SizedBox(height: 15),
                    Text('AI is scanning your label...', 
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.green)),
                  ],
                ),
              )
            else if (_result.isNotEmpty) 
              Container(
                padding: const EdgeInsets.all(15), 
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.green.shade100),
                ),
                child: SelectableText(
                  _result,
                  style: const TextStyle(fontSize: 15, height: 1.5),
                ),
              ),
          ],
        ),
      ),
    );
  }
}