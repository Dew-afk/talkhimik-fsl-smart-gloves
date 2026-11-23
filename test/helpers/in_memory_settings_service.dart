import 'package:talkhimik_app/data/storage/settings_service.dart';

/// In-memory [SettingsService] with the same defaults as the real one —
/// widget tests use this so nothing touches shared_preferences.
class InMemorySettingsService implements SettingsService {
  /// Public fields for test setup; names deliberately avoid the interface
  /// methods, which can't share names with fields of the same identifier.
  String language = 'fil';
  bool muted = false;
  String participant = '';
  bool consent = false;

  double _rate = 1.0;
  String? _voice;
  bool _largeText = true;
  DateTime? _consentAt;
  bool _forceMock = false;
  String? _demoScenario;
  String _signingHand = 'auto';
  bool _phoneRecognitionEnabled = true;

  @override
  Future<String> outputLanguage() async => language;
  @override
  Future<void> setOutputLanguage(String value) async => language = value;
  @override
  Future<double> ttsRate() async => _rate;
  @override
  Future<void> setTtsRate(double value) async => _rate = value;
  @override
  Future<String?> ttsVoice() async => _voice;
  @override
  Future<void> setTtsVoice(String? value) async => _voice = value;
  @override
  Future<bool> ttsMuted() async => muted;
  @override
  Future<void> setTtsMuted(bool value) async => muted = value;
  @override
  Future<bool> largeText() async => _largeText;
  @override
  Future<void> setLargeText(bool value) async => _largeText = value;
  @override
  Future<String> participantId() async => participant;
  @override
  Future<void> setParticipantId(String value) async => participant = value;
  @override
  Future<bool> consentGiven() async => consent;
  @override
  Future<void> setConsentGiven(bool value) async => consent = value;
  @override
  Future<DateTime?> consentDate() async => _consentAt;
  @override
  Future<void> setConsentDate(DateTime? value) async => _consentAt = value;
  @override
  Future<bool> forceMock() async => _forceMock;
  @override
  Future<void> setForceMock(bool value) async => _forceMock = value;
  @override
  Future<String?> demoScenario() async => _demoScenario;
  @override
  Future<void> setDemoScenario(String? value) async => _demoScenario = value;
  @override
  Future<String> signingHand() async => _signingHand;
  @override
  Future<void> setSigningHand(String value) async => _signingHand = value;
  @override
  Future<bool> phoneRecognitionEnabled() async => _phoneRecognitionEnabled;
  @override
  Future<void> setPhoneRecognitionEnabled(bool value) async =>
      _phoneRecognitionEnabled = value;

  Set<String> still = {};
  @override
  Future<Set<String>> stillPhrases() async => still;
  @override
  Future<void> setStillPhrases(Set<String> value) async => still = value;

  List<String> words = [];
  @override
  Future<List<String>> customWords() async => words;
  @override
  Future<void> setCustomWords(List<String> value) async => words = value;
}
