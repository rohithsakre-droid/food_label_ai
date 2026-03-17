import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'dart:convert';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false, // Cleaner look for your lab demo
      title: 'AI Food Label Detector',
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

  // 🔑 Updated to Gemini 2.5 Flash for 2026
  // Keep your key as is, but ensure it's active in AI Studio
  final String _apiKey = 'AIzaSyA15WYsPoKcjENIEa97l73QgTl_WknsdPo';

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
    setState(() => _isLoading = true);

    try {
      final imageBytes = await _selectedImage!.readAsBytes();
      final base64Image = base64Encode(imageBytes);

      const prompt = '''
Analyze this food product label and provide:
1. **Product Name**
2. **Ingredients List** - Explain code names (like E471, INS 330 etc.) and their uses.
3. **Nutritional Summary**
4. **Allergens**
5. **Health Rating** (Healthy / Moderate / Unhealthy) with a short reason.
''';

      // ✅ UPDATED URL: Changed 'v1beta' to 'v1' and '1.5-flash' to '2.5-flash'
      final url = Uri.parse(
        'https://generativelanguage.googleapis.com/v1/models/gemini-2.5-flash:generateContent?key=$_apiKey'
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
        // The path to the text response remains the same in v1
        final text = data['candidates'][0]['content']['parts'][0]['text'];
        setState(() {
          _result = text;
          _isLoading = false;
        });
      } else {
        final error = jsonDecode(response.body);
        setState(() {
          _result = 'Error ${response.statusCode}: ${error['error']['message']}\n\n'
              'Tip: Check if gemini-2.5-flash is enabled in your AI Studio project.';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _result = 'Error: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🥫 Food Label Detector'),
        backgroundColor: Colors.green,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 250,
              decoration: BoxDecoration(
                color: Colors.grey[200],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.green, width: 2),
              ),
              child: _selectedImage != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.file(_selectedImage!, fit: BoxFit.cover),
                    )
                  : const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.camera_alt, size: 60, color: Colors.grey),
                          SizedBox(height: 8),
                          Text('Take a food label photo'),
                        ],
                      ),
                    ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _pickImage(ImageSource.camera),
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('Camera'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _pickImage(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library),
                    label: const Text('Gallery'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade700,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (_isLoading)
              const Center(
                child: Column(
                  children: [
                    CircularProgressIndicator(color: Colors.green),
                    SizedBox(height: 12),
                    Text('AI is scanning nutrition data...'),
                  ],
                ),
              )
            else if (_result.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.green.shade200),
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