import 'package:cloud_functions/cloud_functions.dart';

class PlaceSearchSuggestion {
  const PlaceSearchSuggestion({
    required this.placeId,
    required this.primaryText,
    required this.secondaryText,
  });

  final String placeId;
  final String primaryText;
  final String secondaryText;
}

class ResolvedPlace {
  const ResolvedPlace({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;
}

class PlacesSearchService {
  PlacesSearchService._();

  static const Duration _timeout = Duration(seconds: 12);
  static final FirebaseFunctions _functions = FirebaseFunctions.instanceFor(
    region: 'asia-southeast1',
  );

  static Future<List<PlaceSearchSuggestion>> search({
    required String query,
    required double originLatitude,
    required double originLongitude,
  }) async {
    final result = await _functions
        .httpsCallable('placesAutocomplete')
        .call(<String, Object>{
          'input': query.trim(),
          'originLat': originLatitude,
          'originLng': originLongitude,
        })
        .timeout(_timeout);

    final data = result.data;
    if (data is! Map || data['suggestions'] is! List) {
      throw const FormatException('Places Autocomplete ตอบกลับไม่ถูกต้อง');
    }

    return (data['suggestions'] as List)
        .whereType<Map>()
        .map((item) {
          final placeId = item['placeId']?.toString().trim() ?? '';
          final primaryText = item['primaryText']?.toString().trim() ?? '';
          if (placeId.isEmpty || primaryText.isEmpty) return null;
          return PlaceSearchSuggestion(
            placeId: placeId,
            primaryText: primaryText,
            secondaryText: item['secondaryText']?.toString().trim() ?? '',
          );
        })
        .whereType<PlaceSearchSuggestion>()
        .toList(growable: false);
  }

  static Future<ResolvedPlace> resolve(String placeId) async {
    final result = await _functions
        .httpsCallable('placesResolvePlace')
        .call(<String, Object>{'placeId': placeId})
        .timeout(_timeout);

    final data = result.data;
    if (data is! Map || data['latitude'] is! num || data['longitude'] is! num) {
      throw const FormatException('Place Details ตอบกลับไม่ถูกต้อง');
    }

    return ResolvedPlace(
      latitude: (data['latitude'] as num).toDouble(),
      longitude: (data['longitude'] as num).toDouble(),
    );
  }
}
