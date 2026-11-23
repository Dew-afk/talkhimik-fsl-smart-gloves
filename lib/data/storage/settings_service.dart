import 'package:shared_preferences/shared_preferences.dart';

/// Persisted user settings (SRS FR-15, FR-13; demo flags for development).
abstract interface class SettingsService {
  /// 'fil' (default) or 'en'.
  Future<String> outputLanguage();
  Future<void> setOutputLanguage(String value);

  Future<double> ttsRate(); // default 1.0
  Future<void> setTtsRate(double value);

  Future<String?> ttsVoice();
  Future<void> setTtsVoice(String? value);

  Future<bool> ttsMuted();
  Future<void> setTtsMuted(bool value);

  /// Large-text accessibility mode for signer-facing text (FR-15, NFR-7).
  Future<bool> largeText();
  Future<void> setLargeText(bool value);

  /// Anonymized participant id (FR-13, DR-4); empty until set.
  Future<String> participantId();
  Future<void> setParticipantId(String value);

  Future<bool> consentGiven();
  Future<void> setConsentGiven(bool value);

  Future<DateTime?> consentDate();
  Future<void> setConsentDate(DateTime? value);

  /// Dev flag: force the mock glove even on Android (field testing aid).
  Future<bool> forceMock();
  Future<void> setForceMock(bool value);

  /// Dev flag: mock scenario to auto-run at startup, if any.
  Future<String?> demoScenario();
  Future<void> setDemoScenario(String? value);

  /// Which glove the phone recognizer reads: 'auto' (default), 'left', or
  /// 'right'. Auto = the only connected glove, else Right.
  Future<String> signingHand();
  Future<void> setSigningHand(String value);

  /// Developer toggle for phone-side recognition (default ON for real
  /// gloves; forced OFF while the mock drives the transcript).
  Future<bool> phoneRecognitionEnabled();
  Future<void> setPhoneRecognitionEnabled(bool value);

  /// Phrases shown under "still" on the Record screen (default: none).
  Future<Set<String>> stillPhrases();
  Future<void> setStillPhrases(Set<String> value);

  /// Words added on the Record screen, one JSON object each.
  Future<List<String>> customWords();
  Future<void> setCustomWords(List<String> value);
}

/// shared_preferences implementation (Windows/web/Android all supported).
class SharedPrefsSettingsService implements SettingsService {
  SharedPrefsSettingsService([SharedPreferencesAsync? prefs])
      : _prefs = prefs ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _prefs;

  static const _kLanguage = 'settings.outputLanguage';
  static const _kTtsRate = 'settings.ttsRate';
  static const _kTtsVoice = 'settings.ttsVoice';
  static const _kTtsMuted = 'settings.ttsMuted';
  static const _kLargeText = 'settings.largeText';
  static const _kParticipantId = 'settings.participantId';
  static const _kConsentGiven = 'settings.consentGiven';
  static const _kConsentDate = 'settings.consentDate';
  static const _kForceMock = 'settings.forceMock';
  static const _kDemoScenario = 'settings.demoScenario';
  static const _kSigningHand = 'settings.signingHand';
  static const _kPhoneRecognitionEnabled = 'settings.phoneRecognitionEnabled';
  static const _kStillPhrases = 'settings.stillPhrases';
  static const _kCustomWords = 'settings.customWords';

  @override
  Future<String> outputLanguage() async =>
      await _prefs.getString(_kLanguage) ?? 'fil';

  @override
  Future<void> setOutputLanguage(String value) =>
      _prefs.setString(_kLanguage, value);

  @override
  Future<double> ttsRate() async =>
      await _prefs.getDouble(_kTtsRate) ?? 1.0;

  @override
  Future<void> setTtsRate(double value) => _prefs.setDouble(_kTtsRate, value);

  @override
  Future<String?> ttsVoice() => _prefs.getString(_kTtsVoice);

  @override
  Future<void> setTtsVoice(String? value) =>
      value == null ? _prefs.remove(_kTtsVoice) : _prefs.setString(_kTtsVoice, value);

  @override
  Future<bool> ttsMuted() async => await _prefs.getBool(_kTtsMuted) ?? false;

  @override
  Future<void> setTtsMuted(bool value) => _prefs.setBool(_kTtsMuted, value);

  @override
  Future<bool> largeText() async =>
      await _prefs.getBool(_kLargeText) ?? true; // NFR-7: large by default

  @override
  Future<void> setLargeText(bool value) => _prefs.setBool(_kLargeText, value);

  @override
  Future<String> participantId() async =>
      await _prefs.getString(_kParticipantId) ?? '';

  @override
  Future<void> setParticipantId(String value) =>
      _prefs.setString(_kParticipantId, value);

  @override
  Future<bool> consentGiven() async =>
      await _prefs.getBool(_kConsentGiven) ?? false;

  @override
  Future<void> setConsentGiven(bool value) =>
      _prefs.setBool(_kConsentGiven, value);

  @override
  Future<DateTime?> consentDate() async {
    final millis = await _prefs.getInt(_kConsentDate);
    return millis == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  @override
  Future<void> setConsentDate(DateTime? value) => value == null
      ? _prefs.remove(_kConsentDate)
      : _prefs.setInt(_kConsentDate, value.millisecondsSinceEpoch);

  @override
  Future<bool> forceMock() async =>
      await _prefs.getBool(_kForceMock) ?? false;

  @override
  Future<void> setForceMock(bool value) =>
      _prefs.setBool(_kForceMock, value);

  @override
  Future<String?> demoScenario() => _prefs.getString(_kDemoScenario);

  @override
  Future<void> setDemoScenario(String? value) =>
      value == null ? _prefs.remove(_kDemoScenario) : _prefs.setString(_kDemoScenario, value);

  @override
  Future<String> signingHand() async =>
      await _prefs.getString(_kSigningHand) ?? 'auto';

  @override
  Future<void> setSigningHand(String value) =>
      _prefs.setString(_kSigningHand, value);

  @override
  Future<bool> phoneRecognitionEnabled() async =>
      await _prefs.getBool(_kPhoneRecognitionEnabled) ?? true;

  @override
  Future<void> setPhoneRecognitionEnabled(bool value) =>
      _prefs.setBool(_kPhoneRecognitionEnabled, value);

  @override
  Future<Set<String>> stillPhrases() async =>
      (await _prefs.getStringList(_kStillPhrases) ?? const []).toSet();

  @override
  Future<void> setStillPhrases(Set<String> value) =>
      _prefs.setStringList(_kStillPhrases, value.toList());

  @override
  Future<List<String>> customWords() async =>
      await _prefs.getStringList(_kCustomWords) ?? const [];

  @override
  Future<void> setCustomWords(List<String> value) =>
      _prefs.setStringList(_kCustomWords, value);
}
