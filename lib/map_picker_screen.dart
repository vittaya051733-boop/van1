import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';

import 'services/places_search_service.dart';
import 'utils/app_colors.dart';

class MapPickerScreen extends StatefulWidget {
  final double? initialLatitude;
  final double? initialLongitude;

  const MapPickerScreen({
    super.key,
    this.initialLatitude,
    this.initialLongitude,
  });

  @override
  State<MapPickerScreen> createState() => _MapPickerScreenState();
}

class _MapPickerScreenState extends State<MapPickerScreen> {
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;
  GoogleMapController? _mapController;
  LatLng _selectedPosition = const LatLng(13.7563, 100.5018);
  bool _isLoadingLocation = false;
  List<PlaceSearchSuggestion> _suggestions = const <PlaceSearchSuggestion>[];

  @override
  void initState() {
    super.initState();
    if (widget.initialLatitude != null && widget.initialLongitude != null) {
      _selectedPosition = LatLng(
        widget.initialLatitude!,
        widget.initialLongitude!,
      );
    } else {
      _getCurrentLocation();
    }
  }

  Future<void> _getCurrentLocation() async {
    setState(() => _isLoadingLocation = true);

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _showSnackBar('กรุณาเปิด GPS');
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _showSnackBar('กรุณาอนุญาตการใช้งาน GPS');
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        _showSnackBar('กรุณาเปิดการอนุญาต GPS ในการตั้งค่า');
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      setState(() {
        _selectedPosition = LatLng(position.latitude, position.longitude);
      });

      await _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(_selectedPosition, 16),
      );
    } catch (e) {
      _showSnackBar('ไม่สามารถดึงตำแหน่งได้: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoadingLocation = false);
      }
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _searchLocation([String? submittedValue]) async {
    final query = (submittedValue ?? _searchController.text).trim();
    if (query.isEmpty || _isSearching) return;

    FocusScope.of(context).unfocus();
    setState(() => _isSearching = true);

    try {
      final suggestions = await PlacesSearchService.search(
        query: query,
        originLatitude: _selectedPosition.latitude,
        originLongitude: _selectedPosition.longitude,
      );
      if (!mounted) return;
      if (suggestions.isEmpty) {
        await _searchAddressFallback(query);
        return;
      }
      setState(() => _suggestions = suggestions);
    } catch (e) {
      debugPrint('Google Places search failed: $e');
      await _searchAddressFallback(query);
    } finally {
      if (mounted) {
        setState(() => _isSearching = false);
      }
    }
  }

  Future<void> _searchAddressFallback(String query) async {
    try {
      await setLocaleIdentifier('th_TH');
      var locations = await locationFromAddress(query);
      if (locations.isEmpty && !query.contains('ประเทศไทย')) {
        locations = await locationFromAddress('$query, ประเทศไทย');
      }
      if (locations.isEmpty) {
        _showSnackBar('ไม่พบสถานที่หรือที่อยู่ที่ค้นหา');
        return;
      }
      final location = locations.first;
      await _moveToPosition(location.latitude, location.longitude);
    } catch (e) {
      debugPrint('Address fallback search failed: $e');
      _showSnackBar('ค้นหาสถานที่ไม่สำเร็จ กรุณาลองใหม่');
    }
  }

  Future<void> _selectSuggestion(PlaceSearchSuggestion suggestion) async {
    setState(() {
      _isSearching = true;
      _suggestions = const <PlaceSearchSuggestion>[];
      _searchController.text = suggestion.primaryText;
    });
    try {
      final place = await PlacesSearchService.resolve(suggestion.placeId);
      await _moveToPosition(place.latitude, place.longitude);
    } catch (e) {
      debugPrint('Google Place resolve failed: $e');
      _showSnackBar('ไม่สามารถเปิดสถานที่นี้ได้ กรุณาลองใหม่');
    } finally {
      if (mounted) {
        setState(() => _isSearching = false);
      }
    }
  }

  Future<void> _moveToPosition(double latitude, double longitude) async {
    final position = LatLng(latitude, longitude);
    if (!mounted) return;
    setState(() => _selectedPosition = position);
    await _mapController?.animateCamera(
      CameraUpdate.newLatLngZoom(position, 16),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('เลือกตำแหน่งร้านค้า'),
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: () {
              Navigator.of(context).pop({
                'latitude': _selectedPosition.latitude,
                'longitude': _selectedPosition.longitude,
              });
            },
            tooltip: 'ยืนยันตำแหน่ง',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Material(
              elevation: 2,
              borderRadius: BorderRadius.circular(8),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'ค้นหาสถานที่หรือที่อยู่...',
                  prefixIcon: IconButton(
                    tooltip: 'ค้นหา',
                    onPressed: _isSearching ? null : _searchLocation,
                    icon: const Icon(Icons.search),
                  ),
                  suffixIcon: _isSearching
                      ? const Padding(
                          padding: EdgeInsets.all(12.0),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : (_searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(
                                    () => _suggestions =
                                        const <PlaceSearchSuggestion>[],
                                  );
                                },
                              )
                            : null),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    vertical: 0,
                    horizontal: 8,
                  ),
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: _searchLocation,
                onChanged: (_) => setState(() {}),
              ),
            ),
          ),
          if (_suggestions.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: Material(
                elevation: 3,
                color: Colors.white,
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: _suggestions.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final suggestion = _suggestions[index];
                    return ListTile(
                      leading: const Icon(
                        Icons.location_on_outlined,
                        color: AppColors.accent,
                      ),
                      title: Text(
                        suggestion.primaryText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: suggestion.secondaryText.isEmpty
                          ? null
                          : Text(
                              suggestion.secondaryText,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                      onTap: () => _selectSuggestion(suggestion),
                    );
                  },
                ),
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Stack(
                  children: [
                    Positioned.fill(
                      child: SizedBox(
                        width: constraints.maxWidth,
                        height: constraints.maxHeight,
                        child: GoogleMap(
                          initialCameraPosition: CameraPosition(
                            target: _selectedPosition,
                            zoom: 16,
                          ),
                          onMapCreated: (controller) {
                            _mapController = controller;
                            controller.moveCamera(
                              CameraUpdate.newLatLngZoom(_selectedPosition, 16),
                            );
                          },
                          onTap: (position) {
                            setState(() => _selectedPosition = position);
                          },
                          markers: {
                            Marker(
                              markerId: const MarkerId('selected'),
                              position: _selectedPosition,
                              draggable: true,
                              onDragEnd: (position) {
                                setState(() => _selectedPosition = position);
                              },
                              icon: BitmapDescriptor.defaultMarkerWithHue(
                                BitmapDescriptor.hueOrange,
                              ),
                            ),
                          },
                          myLocationEnabled: true,
                          myLocationButtonEnabled: false,
                          zoomControlsEnabled: false,
                          mapToolbarEnabled: false,
                        ),
                      ),
                    ),
                    Positioned(
                      top: 10,
                      left: 16,
                      right: 16,
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'พิกัดที่เลือก:',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Lat: ${_selectedPosition.latitude.toStringAsFixed(6)}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              Text(
                                'Lng: ${_selectedPosition.longitude.toStringAsFixed(6)}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                '💡 แตะบนแผนที่เพื่อเลือกตำแหน่ง\nหรือลากหมุดเพื่อปรับ',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 80,
                      right: 16,
                      child: FloatingActionButton(
                        backgroundColor: Colors.white,
                        onPressed: _isLoadingLocation
                            ? null
                            : _getCurrentLocation,
                        child: _isLoadingLocation
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(
                                Icons.my_location,
                                color: AppColors.accent,
                              ),
                      ),
                    ),
                    Positioned(
                      bottom: 16,
                      left: 16,
                      right: 16,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.of(context).pop({
                            'latitude': _selectedPosition.latitude,
                            'longitude': _selectedPosition.longitude,
                          });
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: const Icon(Icons.check_circle),
                        label: const Text(
                          'ยืนยันตำแหน่งนี้',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    _mapController?.dispose();
    super.dispose();
  }
}
