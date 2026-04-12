import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter_dotenv/flutter_dotenv.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    debugPrint("Error: Could not load .env file. Check your assets config.");
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
        useMaterial3: true,
        fontFamily: 'sans-serif',
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFF19E9E)),
      ),
      home: const FoodLabelScreen(),
    );
  }
}

// --- DATA MODELS ---
class AnalysisResult {
  final String productName;
  final List<String> ingredients;
  final String healthRating;
  final int healthScore;
  final String detailedInsights;

  AnalysisResult({
    required this.productName,
    required this.ingredients,
    required this.healthRating,
    required this.healthScore,
    required this.detailedInsights,
  });

  factory AnalysisResult.fromJson(Map<String, dynamic> json) {
    var rawIngredients = json['ingredients_full_list'] ?? 'Unknown';
    List<String> ingredientList = rawIngredients.toString().split(RegExp(r',|;')).map((e) => e.trim()).toList();

    return AnalysisResult(
      productName: json['product_name'] ?? 'Product Unidentified',
      ingredients: ingredientList,
      healthRating: json['health_rating'] ?? 'Moderate',
      healthScore: int.tryParse(json['health_score'].toString()) ?? 50,
      detailedInsights: json['insights'] ?? 'No detailed analysis available.',
    );
  }
}

// --- MAIN SCREEN ---
class FoodLabelScreen extends StatefulWidget {
  const FoodLabelScreen({super.key});
  @override
  State<FoodLabelScreen> createState() => _FoodLabelScreenState();
}

class _FoodLabelScreenState extends State<FoodLabelScreen> with SingleTickerProviderStateMixin {
  File? _selectedImage;
  AnalysisResult? _analysisResult;
  bool _isLoading = false;
  final ImagePicker _picker = ImagePicker();
  late AnimationController _scanController;

  @override
  void initState() {
    super.initState();
    _scanController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _scanController.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    final XFile? file = await _picker.pickImage(source: source);
    if (file != null) {
      setState(() {
        _selectedImage = File(file.path);
        _analysisResult = null;
      });
      await _analyzeLabel();
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Scan Interrupted"),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("OK"),
          ),
        ],
      ),
    );
  }

  Future<void> _analyzeLabel() async {
    if (_selectedImage == null) return;
    final String apiKey = dotenv.env['GEMINI_API_KEY']?.trim() ?? '';
    
    if (apiKey.isEmpty) {
      _showErrorDialog("API Key is missing. Check your .env file.");
      return;
    }

    setState(() => _isLoading = true);

    try {
      final imageBytes = await _selectedImage!.readAsBytes();
      final base64Image = base64Encode(imageBytes);

      const prompt = '''
        Analyze this food label image. Return ONLY a JSON object:
        {
          "product_name": "string",
          "ingredients_full_list": "comma separated string of ingredients with chemical names in parentheses",
          "health_rating": "Healthy" | "Moderate" | "Unhealthy",
          "health_score": number (1-100),
          "insights": "2-3 sentences focusing on additives, sugar, and sodium."
        }
      ''';

      final url = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$apiKey',
      );

      int retryCount = 0;
      final List<int> retryDelays = [1, 2, 4, 8, 16];
      http.Response? response;

      while (retryCount <= 5) {
        try {
          response = await http.post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'contents': [{
                'parts': [
                  {'text': prompt},
                  {'inline_data': {'mime_type': 'image/jpeg', 'data': base64Image}}
                ]
              }],
              'generationConfig': {'response_mime_type': 'application/json'}
            }),
          ).timeout(const Duration(seconds: 25));

          if (response.statusCode == 200) {
            break; 
          } else if (response.statusCode == 429 && retryCount < 5) {
            await Future.delayed(Duration(seconds: retryDelays[retryCount]));
            retryCount++;
            continue;
          } else {
            break;
          }
        } catch (e) {
          if (retryCount < 5) {
            await Future.delayed(Duration(seconds: retryDelays[retryCount]));
            retryCount++;
            continue;
          }
          rethrow;
        }
      }

      if (response != null && response.statusCode == 200) {
        final data = jsonDecode(response.body);
        String jsonString = data['candidates'][0]['content']['parts'][0]['text'];
        jsonString = jsonString.replaceAll('```json', '').replaceAll('```', '').trim();

        setState(() {
          _analysisResult = AnalysisResult.fromJson(jsonDecode(jsonString));
          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
        _showErrorDialog("The AI server is busy or returned an error (${response?.statusCode}). Please try again in a moment.");
      }
    } catch (e) {
      setState(() => _isLoading = false);
      _showErrorDialog("The scan failed. Check your internet or try again.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Background Base Color (Off-white/pinkish)
          Container(color: const Color(0xFFFDE6E6)),
          
          // Diagonal Pink Shape - Slope adjusted to match Figma
          const DiagonalBackgroundShape(),

          // Grid Overlay - Subtle and properly scaled
          const GridPainterWidget(),
          
          SafeArea(
            child: _analysisResult == null ? _buildHomeContent() : _buildResultsContent(),
          ),
        ],
      ),
    );
  }

  Widget _buildHomeContent() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 30),
          const Text(
            "Food Label AI",
            style: TextStyle(
              fontSize: 52,
              fontWeight: FontWeight.w900,
              color: Color(0xFF333333),
              letterSpacing: -1.5,
            ),
          ),
          const Text(
            "Scan any food label to analyze ingredients and health",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 35),
          
          // Image Frame with specific brown/red border from design
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(40),
                border: Border.all(
                  color: const Color(0xFF9E6464), // Figma border color
                  width: 12,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _selectedImage != null 
                      ? Image.file(_selectedImage!, fit: BoxFit.cover)
                      : Container(),
                    if (_isLoading) _buildScanningAnimation(),
                  ],
                ),
              ),
            ),
          ),
          
          const SizedBox(height: 35),
          
          // Action Buttons - Pill style with semi-transparency
          Row(
            children: [
              _actionBtn(Icons.camera_alt_outlined, "Capture a photo", () => _pickImage(ImageSource.camera)),
              const SizedBox(width: 12),
              _actionBtn(Icons.image_outlined, "Choose from Gallery", () => _pickImage(ImageSource.gallery)),
            ],
          ),
          
          const SizedBox(height: 20),
          // Refined Salad Bowl illustration
          const SaladBowlIllustration(),
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  Widget _buildResultsContent() {
    final res = _analysisResult!;
    return Container(
      margin: const EdgeInsets.all(20),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.95),
        borderRadius: BorderRadius.circular(35),
        border: Border.all(color: const Color(0xFF9E6464), width: 3),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 20, offset: const Offset(0, 10))
        ],
      ),
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Analysis", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Color(0xFF9E6464))),
                IconButton(
                  onPressed: () => setState(() => _analysisResult = null), 
                  icon: const Icon(Icons.close_rounded, color: Colors.black54)
                ),
              ],
            ),
            const Divider(),
            const SizedBox(height: 10),
            Text(res.productName, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Color(0xFF333333))),
            const SizedBox(height: 20),
            _infoRow("Score", "${res.healthScore}/100", true),
            _infoRow("Rating", res.healthRating, false),
            const SizedBox(height: 25),
            const Text("Ingredients List", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8, runSpacing: 8,
              children: res.ingredients.map((ing) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFF19E9E).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFF19E9E).withOpacity(0.3))
                ),
                child: Text(ing, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              )).toList(),
            ),
            const SizedBox(height: 25),
            const Text("AI Insights", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: Colors.grey.withOpacity(0.05),
                borderRadius: BorderRadius.circular(15),
              ),
              child: Text(res.detailedInsights, style: const TextStyle(height: 1.6, fontSize: 14)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value, bool isScore) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text("$label: ", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          Text(
            value, 
            style: TextStyle(
              fontSize: 16, 
              fontWeight: FontWeight.w900, 
              color: isScore ? const Color(0xFF9E6464) : Colors.black87
            )
          ),
        ],
      ),
    );
  }

  Widget _actionBtn(IconData icon, String label, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.6),
            borderRadius: BorderRadius.circular(32),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4))
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: Colors.black87, size: 22),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.black87,
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScanningAnimation() {
    return AnimatedBuilder(
      animation: _scanController,
      builder: (context, child) {
        return Stack(
          children: [
            Container(color: Colors.black12),
            Positioned(
              top: _scanController.value * 400,
              left: 0, right: 0,
              child: Container(
                height: 6,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.transparent, const Color(0xFF9E6464).withOpacity(0.8), Colors.transparent],
                  ),
                  boxShadow: [BoxShadow(color: const Color(0xFF9E6464).withOpacity(0.4), blurRadius: 15, spreadRadius: 4)],
                ),
              ),
            ),
            const Center(child: CircularProgressIndicator(color: Color(0xFF9E6464), strokeWidth: 5)),
          ],
        );
      },
    );
  }
}

// --- REFINED UI COMPONENTS ---

class DiagonalBackgroundShape extends StatelessWidget {
  const DiagonalBackgroundShape({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: CustomPaint(
        painter: _DiagonalPainter(),
      ),
    );
  }
}

class _DiagonalPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFFF19E9E);
    final path = Path();
    // Adjusted slope to match Figma design
    path.moveTo(0, size.height * 0.38); 
    path.lineTo(size.width, size.height * 0.62); 
    path.lineTo(size.width, size.height);
    path.lineTo(0, size.height);
    path.close();
    canvas.drawPath(path, paint);
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class GridPainterWidget extends StatelessWidget {
  const GridPainterWidget({super.key});
  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size.infinite, painter: _GridPainter());
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFF19E9E).withOpacity(0.15)
      ..strokeWidth = 0.8;
    const double step = 24; // Better grid spacing for the aesthetic
    for (double i = 0; i < size.width; i += step) {
      canvas.drawLine(Offset(i, 0), Offset(i, size.height), paint);
    }
    for (double i = 0; i < size.height; i += step) {
      canvas.drawLine(Offset(0, i), Offset(size.width, i), paint);
    }
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class SaladBowlIllustration extends StatelessWidget {
  const SaladBowlIllustration({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 200,
      width: 320,
      child: CustomPaint(painter: _DetailedSaladBowlPainter()),
    );
  }
}

class _DetailedSaladBowlPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final bottomY = size.height * 0.8;

    // 1. THE BOWL - Better shape with top lip
    final bowlPaint = Paint()..color = const Color(0xFFE55A5A)..style = PaintingStyle.fill;
    final bowlPath = Path();
    bowlPath.moveTo(centerX - 120, bottomY - 90);
    bowlPath.quadraticBezierTo(centerX - 130, bottomY + 20, centerX - 80, bottomY + 40);
    bowlPath.lineTo(centerX + 80, bottomY + 40);
    bowlPath.quadraticBezierTo(centerX + 130, bottomY + 20, centerX + 120, bottomY - 90);
    bowlPath.close();
    canvas.drawPath(bowlPath, bowlPaint);

    // Inner shadow of the bowl
    final shadowPaint = Paint()..color = const Color(0xFFD44B4B)..style = PaintingStyle.fill;
    canvas.drawArc(Rect.fromCenter(center: Offset(centerX, bottomY + 10), width: 200, height: 60), 0, math.pi, false, shadowPaint);

    // 2. INGREDIENTS
    final leafPaint = Paint()..color = const Color(0xFF8BCC64);
    final darkLeafPaint = Paint()..color = const Color(0xFF679B48);
    final tomatoPaint = Paint()..color = const Color(0xFFE94E4E);
    final cucumberPaint = Paint()..color = const Color(0xFFC4E8A2);
    final cucumberDotPaint = Paint()..color = const Color(0xFF679B48).withOpacity(0.6);
    final cornPaint = Paint()..color = const Color(0xFFFFD54F);

    // Lettuce Leaves (Wavy/Multi-circle)
    for (int i = 0; i < 6; i++) {
      double offsetX = centerX - 110 + (i * 45);
      canvas.drawCircle(Offset(offsetX, bottomY - 110), 35, leafPaint);
      canvas.drawCircle(Offset(offsetX + 15, bottomY - 125), 30, darkLeafPaint);
    }

    // Tomato Slices (Detailed with segments)
    _drawDetailedTomato(canvas, centerX - 70, bottomY - 100, tomatoPaint);
    _drawDetailedTomato(canvas, centerX + 70, bottomY - 105, tomatoPaint);
    _drawDetailedTomato(canvas, centerX + 10, bottomY - 80, tomatoPaint);

    // Cucumber Slices (Detailed with dots)
    _drawDetailedCucumber(canvas, centerX - 30, bottomY - 130, cucumberPaint, cucumberDotPaint);
    _drawDetailedCucumber(canvas, centerX + 40, bottomY - 125, cucumberPaint, cucumberDotPaint);
    _drawDetailedCucumber(canvas, centerX - 90, bottomY - 85, cucumberPaint, cucumberDotPaint);

    // Corn Kernels (Small clusters)
    for (var i = 0; i < 15; i++) {
      canvas.drawCircle(Offset(centerX - 100 + (i * 15) + (i % 3 * 5), bottomY - 80 + (i % 2 * 15)), 5, cornPaint);
    }
  }

  void _drawDetailedTomato(Canvas canvas, double x, double y, Paint paint) {
    canvas.drawCircle(Offset(x, y), 32, paint);
    final segmentPaint = Paint()..color = Colors.white.withOpacity(0.4)..style = PaintingStyle.stroke..strokeWidth = 2;
    // Draw cross segment lines
    canvas.drawLine(Offset(x - 20, y), Offset(x + 20, y), segmentPaint);
    canvas.drawLine(Offset(x, y - 20), Offset(x, y + 20), segmentPaint);
    canvas.drawCircle(Offset(x, y), 22, segmentPaint);
  }

  void _drawDetailedCucumber(Canvas canvas, double x, double y, Paint bg, Paint dots) {
    canvas.drawCircle(Offset(x, y), 20, bg);
    // Draw tiny seed dots in a ring
    for (int i = 0; i < 8; i++) {
      double angle = (i * 45) * math.pi / 180;
      canvas.drawCircle(Offset(x + 10 * math.cos(angle), y + 10 * math.sin(angle)), 2.5, dots);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}