import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart'; 

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize REAL Firebase
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // 🔥 ADD THIS LINE: This disables the offline cache and forces network errors to print!
  FirebaseFirestore.instance.settings = const Settings(persistenceEnabled: false);

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
      title: 'Food Label AI',
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'sans-serif',
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFF19E9E)),
      ),
      // Automatically route user based on auth state
      home: FirebaseAuth.instance.currentUser == null ? const LoginScreen() : const FoodLabelScreen(),
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
  final DateTime? scanDate;

  AnalysisResult({
    required this.productName,
    required this.ingredients,
    required this.healthRating,
    required this.healthScore,
    required this.detailedInsights,
    this.scanDate,
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
      scanDate: DateTime.now(),
    );
  }

  // Convert object to a Map for Firestore
  Map<String, dynamic> toMap() {
    return {
      'productName': productName,
      'ingredients': ingredients,
      'healthRating': healthRating,
      'healthScore': healthScore,
      'detailedInsights': detailedInsights,
      'scanDate': scanDate?.toIso8601String(),
    };
  }

  // Create an object from Firestore data
  factory AnalysisResult.fromFirestore(Map<String, dynamic> data) {
    return AnalysisResult(
      productName: data['productName'] ?? 'Unknown',
      ingredients: List<String>.from(data['ingredients'] ?? []),
      healthRating: data['healthRating'] ?? 'Moderate',
      healthScore: data['healthScore'] ?? 50,
      detailedInsights: data['detailedInsights'] ?? 'No insights.',
      scanDate: data['scanDate'] != null ? DateTime.parse(data['scanDate']) : null,
    );
  }
}

// --- REAL FIREBASE SERVICE ---
class FirebaseService {
  static final FirebaseService _instance = FirebaseService._internal();
  factory FirebaseService() => _instance;
  FirebaseService._internal();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  User? get currentUser => _auth.currentUser;

  Future<String?> signUp(String email, String password) async {
    try {
      await _auth.createUserWithEmailAndPassword(email: email, password: password);
      return null; // Success
    } on FirebaseAuthException catch (e) {
      if (e.code == 'weak-password') return 'The password provided is too weak.';
      if (e.code == 'email-already-in-use') return 'An account already exists for that email.';
      return e.message;
    } catch (e) {
      return 'An unknown error occurred.';
    }
  }

  Future<String?> login(String email, String password) async {
    try {
      await _auth.signInWithEmailAndPassword(email: email, password: password);
      return null; // Success
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-not-found' || e.code == 'wrong-password' || e.code == 'invalid-credential') {
        return 'Invalid email or password.';
      }
      return e.message;
    } catch (e) {
      return 'An unknown error occurred.';
    }
  }

  // DIAGNOSTIC SAVE METHOD
  Future<void> saveScan(AnalysisResult result) async {
    if (currentUser == null) {
      debugPrint("❌ ERROR: No user logged in.");
      return;
    }
    
    debugPrint("⏳ Handing data to Firebase (Local Cache)...");
    
    // Notice: We removed "await" and added .then() and .catchError()
    _firestore
        .collection('users')
        .doc(currentUser!.uid)
        .collection('scans')
        .add(result.toMap())
        .then((value) => debugPrint("✅ SUCCESS: Google servers finally received the data!"))
        .catchError((error) => debugPrint("🚨 FIRESTORE REJECTED THE DATA: $error"));
  }

  Future<List<AnalysisResult>> getHistory() async {
    if (currentUser == null) return [];

    try {
      QuerySnapshot snapshot = await _firestore
          .collection('users')
          .doc(currentUser!.uid)
          .collection('scans')
          .orderBy('scanDate', descending: true)
          .get();

      return snapshot.docs.map((doc) {
        return AnalysisResult.fromFirestore(doc.data() as Map<String, dynamic>);
      }).toList();
      
    } catch (e) {
      debugPrint("Error fetching history: $e");
      return [];
    }
  }
  
  Future<void> logout() async {
    await _auth.signOut();
  }
}

// --- LOGIN & SIGN UP SCREEN ---
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  
  bool _isLoading = false;
  bool _isLoginMode = true; 

  Future<void> _handleSubmit() async {
    FocusScope.of(context).unfocus(); 
    setState(() => _isLoading = true);
    
    String email = _emailController.text.trim();
    String password = _passwordController.text.trim();
    String? errorMessage;

    if (_isLoginMode) {
      errorMessage = await FirebaseService().login(email, password);
    } else {
      if (password != _confirmPasswordController.text.trim()) {
        errorMessage = "Passwords do not match.";
      } else {
        errorMessage = await FirebaseService().signUp(email, password);
      }
    }

    setState(() => _isLoading = false);

    if (errorMessage == null && mounted) {
      Navigator.pushReplacement(
        context, 
        MaterialPageRoute(builder: (_) => const FoodLabelScreen())
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMessage ?? "An error occurred"),
          backgroundColor: Colors.red.shade800,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(color: const Color(0xFFFDE6E6)),
          const DiagonalBackgroundShape(),
          const GridPainterWidget(),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 32.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _isLoginMode ? "Welcome Back" : "Create Account",
                      style: const TextStyle(
                        fontSize: 42,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF333333),
                        letterSpacing: -1.0,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _isLoginMode 
                        ? "Sign in to access your Food Label AI" 
                        : "Join us to start analyzing your food",
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 40),
                    
                    _buildTextField("Email", Icons.email_outlined, _emailController, false),
                    const SizedBox(height: 20),
                    _buildTextField("Password", Icons.lock_outline, _passwordController, true),
                    
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      height: _isLoginMode ? 0 : 80,
                      curve: Curves.easeInOut,
                      child: SingleChildScrollView(
                        physics: const NeverScrollableScrollPhysics(),
                        child: Column(
                          children: [
                            const SizedBox(height: 20),
                            _buildTextField("Confirm Password", Icons.lock_reset, _confirmPasswordController, true),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 30),
                    
                    _isLoading 
                      ? const CircularProgressIndicator(color: Color(0xFF9E6464))
                      : SizedBox(
                          width: double.infinity,
                          height: 56,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF9E6464),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                              elevation: 2,
                            ),
                            onPressed: _handleSubmit,
                            child: Text(
                              _isLoginMode ? "Log In" : "Sign Up", 
                              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)
                            ),
                          ),
                        ),
                    
                    const SizedBox(height: 20),
                    
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _isLoginMode = !_isLoginMode;
                          _emailController.clear();
                          _passwordController.clear();
                          _confirmPasswordController.clear();
                        });
                      },
                      child: Text(
                        _isLoginMode 
                          ? "Don't have an account? Sign Up" 
                          : "Already have an account? Log In",
                        style: const TextStyle(
                          color: Color(0xFF333333),
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField(String hint, IconData icon, TextEditingController controller, bool isPassword) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.9),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF9E6464).withOpacity(0.5), width: 2),
      ),
      child: TextField(
        controller: controller,
        obscureText: isPassword,
        keyboardType: isPassword ? TextInputType.text : TextInputType.emailAddress,
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: Icon(icon, color: const Color(0xFF9E6464)),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        ),
      ),
    );
  }
}

// --- HISTORY SCREEN ---
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDE6E6),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text("Scan History", style: TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF333333))),
        iconTheme: const IconThemeData(color: Color(0xFF333333)),
      ),
      body: Stack(
        children: [
          const GridPainterWidget(),
          FutureBuilder<List<AnalysisResult>>(
            future: FirebaseService().getHistory(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator(color: Color(0xFF9E6464)));
              }
              if (!snapshot.hasData || snapshot.data!.isEmpty) {
                return const Center(
                  child: Text("No scans yet. Start scanning!", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                );
              }

              final history = snapshot.data!;
              return ListView.builder(
                padding: const EdgeInsets.all(20),
                itemCount: history.length,
                itemBuilder: (context, index) {
                  final item = history[index];
                  return Card(
                    margin: const EdgeInsets.only(bottom: 16),
                    elevation: 4,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    color: Colors.white.withOpacity(0.95),
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(16),
                      title: Text(item.productName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: Text("Health Score: ${item.healthScore}/100\nRating: ${item.healthRating}", style: const TextStyle(height: 1.4)),
                      ),
                      trailing: const Icon(Icons.analytics_outlined, color: Color(0xFF9E6464), size: 28),
                      isThreeLine: true,
                    ),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

// --- MAIN SCANNER SCREEN ---
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

        final parsedResult = AnalysisResult.fromJson(jsonDecode(jsonString));
        
        // Save scan using our new diagnostic method
        FirebaseService().saveScan(parsedResult);

        setState(() {
          _analysisResult = parsedResult;
          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
        _showErrorDialog("The AI server is busy or returned an error (${response?.statusCode}). Please try again in a moment.");
      }
    } catch (e) {
      setState(() => _isLoading = false);
      _showErrorDialog("The scan failed. Check your internet connection or try again.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(color: const Color(0xFFFDE6E6)),
          const DiagonalBackgroundShape(),
          const GridPainterWidget(),
          
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.history, color: Color(0xFF333333), size: 28),
                        tooltip: "Scan History",
                        onPressed: () {
                          Navigator.push(context, MaterialPageRoute(builder: (_) => const HistoryScreen()));
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.logout, color: Color(0xFF333333), size: 26),
                        tooltip: "Log Out",
                        onPressed: () async {
                          await FirebaseService().logout();
                          if (context.mounted) {
                            Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
                          }
                        },
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _analysisResult == null ? _buildHomeContent() : _buildResultsContent(),
                ),
              ],
            ),
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
          const SizedBox(height: 25),
          
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(40),
                border: Border.all(
                  color: const Color(0xFF9E6464),
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
          
          const SizedBox(height: 25),
          
          Row(
            children: [
              _actionBtn(Icons.camera_alt_outlined, "Capture a photo", () => _pickImage(ImageSource.camera)),
              const SizedBox(width: 12),
              _actionBtn(Icons.image_outlined, "Choose from Gallery", () => _pickImage(ImageSource.gallery)),
            ],
          ),
          
          const SizedBox(height: 10),
          const SaladBowlIllustration(),
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

// --- BACKGROUND COMPONENTS ---
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
    const double step = 24; 
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

    final bowlPaint = Paint()..color = const Color(0xFFE55A5A)..style = PaintingStyle.fill;
    final bowlPath = Path();
    bowlPath.moveTo(centerX - 120, bottomY - 90);
    bowlPath.quadraticBezierTo(centerX - 130, bottomY + 20, centerX - 80, bottomY + 40);
    bowlPath.lineTo(centerX + 80, bottomY + 40);
    bowlPath.quadraticBezierTo(centerX + 130, bottomY + 20, centerX + 120, bottomY - 90);
    bowlPath.close();
    canvas.drawPath(bowlPath, bowlPaint);

    final shadowPaint = Paint()..color = const Color(0xFFD44B4B)..style = PaintingStyle.fill;
    canvas.drawArc(Rect.fromCenter(center: Offset(centerX, bottomY + 10), width: 200, height: 60), 0, math.pi, false, shadowPaint);

    final leafPaint = Paint()..color = const Color(0xFF8BCC64);
    final darkLeafPaint = Paint()..color = const Color(0xFF679B48);
    final tomatoPaint = Paint()..color = const Color(0xFFE94E4E);
    final cucumberPaint = Paint()..color = const Color(0xFFC4E8A2);
    final cucumberDotPaint = Paint()..color = const Color(0xFF679B48).withOpacity(0.6);
    final cornPaint = Paint()..color = const Color(0xFFFFD54F);

    for (int i = 0; i < 6; i++) {
      double offsetX = centerX - 110 + (i * 45);
      canvas.drawCircle(Offset(offsetX, bottomY - 110), 35, leafPaint);
      canvas.drawCircle(Offset(offsetX + 15, bottomY - 125), 30, darkLeafPaint);
    }

    _drawDetailedTomato(canvas, centerX - 70, bottomY - 100, tomatoPaint);
    _drawDetailedTomato(canvas, centerX + 70, bottomY - 105, tomatoPaint);
    _drawDetailedTomato(canvas, centerX + 10, bottomY - 80, tomatoPaint);

    _drawDetailedCucumber(canvas, centerX - 30, bottomY - 130, cucumberPaint, cucumberDotPaint);
    _drawDetailedCucumber(canvas, centerX + 40, bottomY - 125, cucumberPaint, cucumberDotPaint);
    _drawDetailedCucumber(canvas, centerX - 90, bottomY - 85, cucumberPaint, cucumberDotPaint);

    for (var i = 0; i < 15; i++) {
      canvas.drawCircle(Offset(centerX - 100 + (i * 15) + (i % 3 * 5), bottomY - 80 + (i % 2 * 15)), 5, cornPaint);
    }
  }

  void _drawDetailedTomato(Canvas canvas, double x, double y, Paint paint) {
    canvas.drawCircle(Offset(x, y), 32, paint);
    final segmentPaint = Paint()..color = Colors.white.withOpacity(0.4)..style = PaintingStyle.stroke..strokeWidth = 2;
    canvas.drawLine(Offset(x - 20, y), Offset(x + 20, y), segmentPaint);
    canvas.drawLine(Offset(x, y - 20), Offset(x, y + 20), segmentPaint);
    canvas.drawCircle(Offset(x, y), 22, segmentPaint);
  }

  void _drawDetailedCucumber(Canvas canvas, double x, double y, Paint bg, Paint dots) {
    canvas.drawCircle(Offset(x, y), 20, bg);
    for (int i = 0; i < 8; i++) {
      double angle = (i * 45) * math.pi / 180;
      canvas.drawCircle(Offset(x + 10 * math.cos(angle), y + 10 * math.sin(angle)), 2.5, dots);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}