import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../theme/app_theme.dart';
import '../../../core/config.dart';

enum _SearchFilter { all, ayahs, hadiths, tafsir }

class _SearchResult {
  const _SearchResult({
    required this.chunkId,
    required this.sourceType,
    required this.finalRank,
    required this.rerankerScore,
    required this.chunk,
    this.note,
    this.comparativeConcept,
  });

  factory _SearchResult.fromJson(Map<String, dynamic> json) {
    return _SearchResult(
      chunkId: json['chunk_id'] as String? ?? '',
      sourceType: json['source_type'] as String? ?? '',
      finalRank: (json['final_rank'] as num?)?.toInt() ?? 0,
      rerankerScore: (json['reranker_score'] as num?)?.toDouble() ?? 0,
      chunk: (json['chunk'] as Map?)?.cast<String, dynamic>() ?? const {},
      note: json['note'] as String?,
      comparativeConcept: json['comparative_concept'] as String?,
    );
  }

  final String chunkId;
  final String sourceType;
  final int finalRank;
  final double rerankerScore;
  final Map<String, dynamic> chunk;
  final String? note;
  final String? comparativeConcept;

  bool get isQuran => sourceType.startsWith('Quran');
  bool get isHadith => sourceType.startsWith('Hadith');
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, this.initialQuery = ''});

  /// Pre-fills the search box and runs the query on open (used when navigating
  /// here from the "Search Meaning" action on the recitation results page).
  final String initialQuery;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  static const List<_SearchFilter> _filters = [
    _SearchFilter.all,
    _SearchFilter.ayahs,
    _SearchFilter.hadiths,
  ];

  final TextEditingController _searchController = TextEditingController();
  final http.Client _client = http.Client();

  Timer? _debounceTimer;
  _SearchFilter _selectedFilter = _SearchFilter.all;
  List<_SearchResult> _results = const [];
  bool _isCheckingServer = true;
  bool _isSearching = false;
  String? _healthError;
  String? _searchError;
  bool _wasRouteCurrent = false;
  int _currentTopK = 10;

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.isNotEmpty) {
      _searchController.text = widget.initialQuery;
    }
    _checkServerHealth();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    final isCurrent = route?.isCurrent ?? false;
    if (isCurrent && !_wasRouteCurrent) {
      _wasRouteCurrent = true;
      _checkServerHealth();
    } else if (!isCurrent) {
      _wasRouteCurrent = false;
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.dispose();
    _client.close();
    super.dispose();
  }

  static Uri get _baseUri {
    return apiBaseUri;
  }

  static String _filterLabel(_SearchFilter filter) {
    switch (filter) {
      case _SearchFilter.all:
        return 'All';
      case _SearchFilter.ayahs:
        return 'Quran';
      case _SearchFilter.hadiths:
        return 'Hadiths';
      case _SearchFilter.tafsir:
        return 'Quran';
    }
  }

  static String? _filterScope(_SearchFilter filter) {
    switch (filter) {
      case _SearchFilter.all:
        return null;
      case _SearchFilter.ayahs:
      case _SearchFilter.tafsir:
        return 'quran';
      case _SearchFilter.hadiths:
        return 'hadith';
    }
  }

  static bool _matchesFilter(_SearchResult result, _SearchFilter filter) {
    switch (filter) {
      case _SearchFilter.all:
        return true;
      case _SearchFilter.ayahs:
        return result.sourceType == 'Quran_Tafsir' ||
            result.sourceType == 'Quran_Passage';
      case _SearchFilter.hadiths:
        return result.isHadith;
      case _SearchFilter.tafsir:
        return result.sourceType == 'Quran_Tafsir' ||
            result.sourceType == 'Quran_Passage';
    }
  }

  static String _sourceLabel(_SearchResult result) {
    switch (result.sourceType) {
      case 'Quran_Tafsir':
        return 'Quran';
      case 'Quran_Passage':
        return 'Quran';
      case 'Hadith':
        return 'Hadith';
      case 'Hadith_Cluster':
        return 'Hadith Cluster';
      default:
        return result.sourceType.replaceAll('_', ' ');
    }
  }

  static String _previewText(_SearchResult result) {
    final chunk = result.chunk;

    final hasMembers = (result.chunk['members'] as List?)?.isNotEmpty == true;

    if (result.sourceType == 'Quran_Passage' ||
        (hasMembers && result.sourceType.startsWith('Quran'))) {
      return chunk['english_translation'] as String? ??
          chunk['arabic_text'] as String? ??
          '';
    }

    if (result.sourceType == 'Hadith_Cluster') {
      final members = (chunk['members'] as List?)?.cast<Map>() ?? const [];
      if (members.isEmpty) {
        return chunk['english_text'] as String? ??
            chunk['arabic_text'] as String? ??
            '';
      }

      return members
          .take(2)
          .map((member) => member['english_text'] as String? ?? '')
          .where((text) => text.trim().isNotEmpty)
          .join('\n\n');
    }

    return chunk['english_translation'] as String? ??
        chunk['english_text'] as String? ??
        chunk['arabic_text'] as String? ??
        '';
  }

  Future<void> _checkServerHealth() async {
    try {
      final healthUri = _baseUri.resolve('health');
      if (kDebugMode) {
        debugPrint('Sending HEALTH request to $healthUri');
      }

      final response = await _client.get(healthUri);
      if (kDebugMode) {
        debugPrint(
          'Health response (${response.statusCode}): ${response.body}',
        );
      }
      if (!mounted) {
        return;
      }

      if (response.statusCode == 200) {
        final payload = jsonDecode(response.body) as Map<String, dynamic>;
        final status = payload['status'] as String?;
        setState(() {
          _isCheckingServer = false;
          _healthError = status == 'ok' ? null : 'Search service is not ready.';
        });
        if (status == 'ok' && _searchController.text.trim().isNotEmpty) {
          _scheduleSearch(immediate: true);
        }
        return;
      }

      setState(() {
        _isCheckingServer = false;
        _healthError = 'Search service returned ${response.statusCode}.';
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isCheckingServer = false;
        _healthError = 'Search service is unavailable.';
      });
    }
  }

  void _scheduleSearch({bool immediate = false, bool isLoadMore = false}) {
    _debounceTimer?.cancel();

    final query = _searchController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _isSearching = false;
        _searchError = null;
        _results = const [];
        _currentTopK = 10;
      });
      return;
    }

    if (_isCheckingServer) {
      return;
    }

    if (!isLoadMore) {
      _currentTopK = 10;
    }

    if (immediate) {
      _runSearch(query);
      return;
    }

    _debounceTimer = Timer(const Duration(milliseconds: 350), () {
      _runSearch(query);
    });
  }

  Future<void> _runSearch(String query) async {
    if (!mounted) {
      return;
    }

    setState(() {
      _isSearching = true;
      _searchError = null;
    });

    try {
      final requestBody = <String, dynamic>{'query': query, 'top_k': _currentTopK};

      final scope = _filterScope(_selectedFilter);
      if (scope != null) {
        requestBody['filters'] = {'scope': scope};
      }

      final searchUri = _baseUri.resolve('search');
      if (kDebugMode) {
        debugPrint('Sending SEARCH request to $searchUri');
        debugPrint('Search request body: ${jsonEncode(requestBody)}');
      }

      final response = await _client.post(
        searchUri,
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode(requestBody),
      );
      if (kDebugMode) {
        debugPrint(
          'Search response (${response.statusCode}): ${response.body}',
        );
      }

      if (!mounted) {
        return;
      }

      if (response.statusCode != 200) {
        throw Exception('Search failed with status ${response.statusCode}.');
      }

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final rawResults = (payload['results'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (result) => _SearchResult.fromJson(result.cast<String, dynamic>()),
          )
          .toList();

      // If the user requested Quran scope but selected the "Ayahs" filter,
      // include multi-ayah passages (Quran_Passage) so results aren't discarded.
      final List<_SearchResult> results = rawResults.where((result) {
        final scope =
            (payload['query_meta'] as Map<String, dynamic>?)?['scope']
                as String?;
        if (_selectedFilter == _SearchFilter.ayahs) {
          if (scope == 'quran') {
            return result.sourceType == 'Quran_Tafsir' ||
                result.sourceType == 'Quran_Passage' ||
                (result.chunk['members'] is List &&
                    (result.chunk['members'] as List).isNotEmpty);
          }
          return result.sourceType == 'Quran_Tafsir';
        }

        return _matchesFilter(result, _selectedFilter);
      }).toList();

      setState(() {
        _results = results;
        _isSearching = false;
        _searchError = payload['error'] as String?;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isSearching = false;
        _searchError = 'Could not load results from the search service.';
        _results = const [];
      });
    }
  }

  Future<Map<String, dynamic>> _fetchChunkDetail(String chunkId) async {
    final chunkUri = _baseUri.resolve('chunk/${Uri.encodeComponent(chunkId)}');
    if (kDebugMode) {
      debugPrint('Sending CHUNK request to $chunkUri for $chunkId');
    }

    final response = await _client.get(chunkUri);
    if (kDebugMode) {
      debugPrint(
        'Chunk response (${response.statusCode}) for $chunkId: ${response.body}',
      );
    }

    if (response.statusCode != 200) {
      throw Exception(
        'Chunk lookup failed with status ${response.statusCode}.',
      );
    }

    return (jsonDecode(response.body) as Map).cast<String, dynamic>();
  }

  Future<void> _openChunkDetail(_SearchResult result) async {
    if (result.chunkId.isEmpty) {
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return FractionallySizedBox(
          heightFactor: 0.9,
          child: Container(
            decoration: const BoxDecoration(
              color: AppTheme.background,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: SafeArea(
              top: false,
              child: FutureBuilder<Map<String, dynamic>>(
                future: _fetchChunkDetail(result.chunkId),
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  if (snapshot.hasError || !snapshot.hasData) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: _SearchStatusPanel(
                          title: 'Chunk not available',
                          message:
                              'The search service could not load ${result.chunkId}.',
                        ),
                      ),
                    );
                  }

                  return _ChunkDetailSheet(
                    result: result,
                    chunk: snapshot.data!,
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final resultCount = _results.length;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search ayah, hadith, or tafsir',
              prefixIcon: const Icon(Icons.search, color: AppTheme.primary),
              suffixIcon: _searchController.text.isEmpty
                  ? null
                  : IconButton(
                      onPressed: () {
                        setState(() {
                          _searchController.clear();
                          _results = const [];
                          _searchError = null;
                          _isSearching = false;
                        });
                      },
                      icon: const Icon(Icons.close),
                    ),
            ),
            onChanged: (_) {
              setState(() {});
              _scheduleSearch();
            },
            onSubmitted: (_) => _scheduleSearch(immediate: true),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: List.generate(_filters.length, (index) {
              final filter = _filters[index];
              final isSelected = _selectedFilter == filter;
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    right: index == _filters.length - 1 ? 0 : 8,
                  ),
                  child: Material(
                    color: isSelected ? AppTheme.primary : Colors.white,
                    borderRadius: BorderRadius.circular(999),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: () {
                        setState(() => _selectedFilter = filter);
                        if (_searchController.text.trim().isNotEmpty) {
                          _scheduleSearch(immediate: true);
                        }
                      },
                      child: Container(
                        height: 40,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: isSelected
                                ? AppTheme.primary
                                : AppTheme.outline,
                          ),
                        ),
                        child: Center(
                          child: Text(
                            _filterLabel(filter),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: isSelected
                                  ? Colors.white
                                  : AppTheme.textPrimary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 12),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Divider(height: 1, thickness: 1, color: AppTheme.outline),
        ),
        const SizedBox(height: 20),
        if (_isCheckingServer)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else
          Expanded(child: _buildResults(context, resultCount)),
      ],
    );
  }

  Widget _buildResults(BuildContext context, int resultCount) {
    final query = _searchController.text.trim();

    if (_healthError != null && query.isEmpty) {
      return _SearchStatusPanel(
        title: 'Search service not ready',
        message: _healthError!,
      );
    }

    if (query.isEmpty) {
      return const _SearchStatusPanel(
        title: 'Search the corpus',
        message:
            'Enter an Arabic, English, or transliterated query to search the indexed Quran and Hadith corpus.',
        centered: true,
      );
    }

    if (_searchError != null && _results.isEmpty) {
      return _SearchStatusPanel(title: 'Search failed', message: _searchError!);
    }

    final bool canLoadMore = _results.isNotEmpty &&
        _currentTopK < 20 &&
        _results.length >= _currentTopK;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Text(
                'TOP MATCH',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.primary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '($resultCount)',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: Colors.black.withValues(alpha: 0.6),
                ),
              ),
              const Spacer(),
              if (_isSearching)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (_results.isEmpty)
          const Expanded(
            child: _SearchStatusPanel(
              title: 'No matches yet',
              message:
                  'Try a more specific query, or switch to a different filter.',
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              itemCount: _results.length + (canLoadMore ? 1 : 0),
              separatorBuilder: (context, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                if (index == _results.length) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppTheme.primary),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        minimumSize: const Size.fromHeight(50),
                      ),
                      onPressed: _isSearching
                          ? null
                          : () {
                              setState(() {
                                _currentTopK = 20;
                              });
                              _scheduleSearch(immediate: true, isLoadMore: true);
                            },
                      child: _isSearching
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  AppTheme.primary,
                                ),
                              ),
                            )
                          : const Text(
                              'View More',
                              style: TextStyle(
                                color: AppTheme.primary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  );
                }

                return _SearchResultCard(
                  result: _results[index],
                  onTap: () => _openChunkDetail(_results[index]),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _SearchStatusPanel extends StatelessWidget {
  const _SearchStatusPanel({
    required this.title,
    required this.message,
    this.centered = false,
  });

  final String title;
  final String message;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    if (centered) {
      return SizedBox.expand(
        child: Container(
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppTheme.outline),
          ),
          alignment: Alignment.center,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.black.withValues(alpha: 0.72),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppTheme.outline),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.black.withValues(alpha: 0.72),
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchResultCard extends StatelessWidget {
  const _SearchResultCard({required this.result, required this.onTap});

  final _SearchResult result;
  final VoidCallback onTap;

  List<Map<String, dynamic>> get _members {
    return (result.chunk['members'] as List? ?? const [])
        .whereType<Map>()
        .map((member) => member.cast<String, dynamic>())
        .toList();
  }

  Widget _buildMemberPreview(BuildContext context) {
    final hasMembers = _members.isNotEmpty;

    if (result.sourceType == 'Quran_Passage' ||
        (hasMembers && result.sourceType.startsWith('Quran'))) {
      final surahName = _surahDisplayName(result.chunk);
      final ayahCount = _members.isNotEmpty ? _members.length : 1;
      final arabicText = result.chunk['arabic_text'] as String? ?? '';
      final englishText =
          result.chunk['english_translation'] as String? ??
          result.chunk['english_text'] as String? ??
          '';

      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.primary.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.primary.withValues(alpha: 0.16)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _ResultBadge(label: surahName.isEmpty ? 'Quran' : surahName),
                const SizedBox(width: 8),
                Text(
                  '$ayahCount ayah${ayahCount == 1 ? '' : 's'}',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Colors.black.withValues(alpha: 0.55),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            if (englishText.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                englishText,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  height: 1.45,
                  color: Colors.black.withValues(alpha: 0.8),
                ),
              ),
            ],
            if (arabicText.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                arabicText,
                textDirection: TextDirection.rtl,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  height: 1.7,
                  color: AppTheme.textPrimary,
                ),
              ),
            ],
          ],
        ),
      );
    }

    if (result.sourceType == 'Hadith_Cluster') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: _members.take(3).map((member) {
          final hadithId = member['hadith_id'];
          final englishText = member['english_text'] as String? ?? '';

          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hadithId == null ? 'Hadith' : 'Hadith $hadithId',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AppTheme.primary,
                  ),
                ),
                if (englishText.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    englishText,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      height: 1.45,
                      color: Colors.black.withValues(alpha: 0.78),
                    ),
                  ),
                ],
              ],
            ),
          );
        }).toList(),
      );
    }

    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    final chunk = result.chunk;
    final title = _SearchPageState._sourceLabel(result);
    final preview = _SearchPageState._previewText(result);
    final reference = _referenceText(result);
    final hasMembers = (chunk['members'] as List?)?.isNotEmpty == true;
    final isGroupedQuran =
        result.sourceType == 'Quran_Passage' ||
        (result.sourceType.startsWith('Quran') && hasMembers);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppTheme.outline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [_ResultBadge(label: title)]),
              if (reference.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  reference,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ],
              if (!isGroupedQuran &&
                  result.sourceType != 'Hadith_Cluster' &&
                  preview.trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  preview,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    height: 1.45,
                    color: Colors.black.withValues(alpha: 0.78),
                  ),
                ),
              ],
              if (isGroupedQuran || result.sourceType == 'Hadith_Cluster') ...[
                const SizedBox(height: 10),
                _buildMemberPreview(context),
              ] else if (chunk['arabic_text'] is String &&
                  (chunk['arabic_text'] as String).trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  chunk['arabic_text'] as String,
                  textDirection: TextDirection.rtl,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    height: 1.7,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ],
              if (result.note != null && result.note!.trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  result.note!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              Container(
                margin: const EdgeInsets.only(top: 14),
                width: double.infinity,
                height: 1,
                color: AppTheme.outline.withValues(alpha: 0.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResultBadge extends StatelessWidget {
  const _ResultBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w800,
          color: AppTheme.primary,
        ),
      ),
    );
  }
}

String _referenceText(_SearchResult result) {
  final chunk = result.chunk;
  final surahName = _surahDisplayName(chunk);

  if (result.sourceType == 'Quran_Tafsir') {
    final surahId = chunk['surah_id'];
    final ayahId = chunk['ayah_id'];
    if (ayahId == null) {
      return '';
    }
    return '${surahName.isNotEmpty ? surahName : _surahNameFromId(surahId)} $ayahId'
        .trim();
  }

  if (result.sourceType == 'Quran_Passage') {
    final surahId = chunk['surah_id'];
    final startAyah = chunk['start_ayah'];
    final endAyah = chunk['end_ayah'];
    if (startAyah == null || endAyah == null) {
      return '';
    }
    return '${surahName.isNotEmpty ? surahName : _surahNameFromId(surahId)} $startAyah-$endAyah'
        .trim();
  }

  if (result.sourceType == 'Hadith') {
    final bookName = chunk['book_name'] as String? ?? '';
    final hadithId = chunk['hadith_id'];
    if (bookName.isEmpty && hadithId == null) {
      return '';
    }
    return [bookName, hadithId].where((part) => part != null).join(' · ');
  }

  if (result.sourceType == 'Hadith_Cluster') {
    final bookName = chunk['book_name'] as String? ?? '';
    final chapterId = chunk['chapter_id'];
    if (bookName.isEmpty && chapterId == null) {
      return '';
    }
    return [bookName, chapterId].where((part) => part != null).join(' · ');
  }

  return '';
}

String _surahDisplayName(Map<String, dynamic> chunk) {
  const candidateKeys = [
    'surah_name',
    'surah_name_en',
    'surah_english_name',
    'surah_arabic_name',
    'surah_title',
  ];

  for (final key in candidateKeys) {
    final value = chunk[key];
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
  }

  return _surahNameFromId(chunk['surah_id']);
}

String _surahNameFromId(dynamic surahId) {
  final id = surahId is num ? surahId.toInt() : int.tryParse('$surahId');
  if (id == null) {
    return '';
  }

  return _surahNames[id] ?? '';
}

const Map<int, String> _surahNames = {
  1: 'Al-Fatiha',
  2: 'Al-Baqarah',
  3: 'Aal-E-Imran',
  4: 'An-Nisa',
  5: 'Al-Maidah',
  6: 'Al-Anam',
  7: 'Al-Araf',
  8: 'Al-Anfal',
  9: 'At-Tawbah',
  10: 'Yunus',
  11: 'Hud',
  12: 'Yusuf',
  13: 'Ar-Rad',
  14: 'Ibrahim',
  15: 'Al-Hijr',
  16: 'An-Nahl',
  17: 'Al-Isra',
  18: 'Al-Kahf',
  19: 'Maryam',
  20: 'Ta-Ha',
  21: 'Al-Anbiya',
  22: 'Al-Hajj',
  23: 'Al-Muminun',
  24: 'An-Nur',
  25: 'Al-Furqan',
  26: 'Ash-Shuara',
  27: 'An-Naml',
  28: 'Al-Qasas',
  29: 'Al-Ankabut',
  30: 'Ar-Rum',
  31: 'Luqman',
  32: 'As-Sajdah',
  33: 'Al-Ahzab',
  34: 'Saba',
  35: 'Fatir',
  36: 'Ya-Sin',
  37: 'As-Saffat',
  38: 'Sad',
  39: 'Az-Zumar',
  40: 'Ghafir',
  41: 'Fussilat',
  42: 'Ash-Shura',
  43: 'Az-Zukhruf',
  44: 'Ad-Dukhan',
  45: 'Al-Jathiyah',
  46: 'Al-Ahqaf',
  47: 'Muhammad',
  48: 'Al-Fath',
  49: 'Al-Hujurat',
  50: 'Qaf',
  51: 'Adh-Dhariyat',
  52: 'At-Tur',
  53: 'An-Najm',
  54: 'Al-Qamar',
  55: 'Ar-Rahman',
  56: 'Al-Waqiah',
  57: 'Al-Hadid',
  58: 'Al-Mujadila',
  59: 'Al-Hashr',
  60: 'Al-Mumtahanah',
  61: 'As-Saff',
  62: 'Al-Jumuah',
  63: 'Al-Munafiqun',
  64: 'At-Taghabun',
  65: 'At-Talaq',
  66: 'At-Tahrim',
  67: 'Al-Mulk',
  68: 'Al-Qalam',
  69: 'Al-Haqqah',
  70: 'Al-Maarij',
  71: 'Nuh',
  72: 'Al-Jinn',
  73: 'Al-Muzzammil',
  74: 'Al-Muddaththir',
  75: 'Al-Qiyamah',
  76: 'Al-Insan',
  77: 'Al-Mursalat',
  78: 'An-Naba',
  79: 'An-Naziat',
  80: 'Abasa',
  81: 'At-Takwir',
  82: 'Al-Infitar',
  83: 'Al-Mutaffifin',
  84: 'Al-Inshiqaq',
  85: 'Al-Buruj',
  86: 'At-Tariq',
  87: 'Al-Ala',
  88: 'Al-Ghashiyah',
  89: 'Al-Fajr',
  90: 'Al-Balad',
  91: 'Ash-Shams',
  92: 'Al-Layl',
  93: 'Ad-Duha',
  94: 'Ash-Sharh',
  95: 'At-Tin',
  96: 'Al-Alaq',
  97: 'Al-Qadr',
  98: 'Al-Bayyinah',
  99: 'Az-Zalzalah',
  100: 'Al-Adiyat',
  101: 'Al-Qariah',
  102: 'At-Takathur',
  103: 'Al-Asr',
  104: 'Al-Humazah',
  105: 'Al-Fil',
  106: 'Quraysh',
  107: 'Al-Maun',
  108: 'Al-Kawthar',
  109: 'Al-Kafirun',
  110: 'An-Nasr',
  111: 'Al-Masad',
  112: 'Al-Ikhlas',
  113: 'Al-Falaq',
  114: 'An-Nas',
};

class _ChunkDetailSheet extends StatelessWidget {
  const _ChunkDetailSheet({required this.result, required this.chunk});

  final _SearchResult result;
  final Map<String, dynamic> chunk;

  List<Map<String, dynamic>> get _members {
    return (chunk['members'] as List? ?? const [])
        .whereType<Map>()
        .map((member) => member.cast<String, dynamic>())
        .toList();
  }

  Widget _buildSection(
    BuildContext context, {
    required String title,
    required String value,
    bool rtl = false,
  }) {
    if (value.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppTheme.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: AppTheme.primary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                height: 1.55,
                color: AppTheme.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMemberList(
    BuildContext context, {
    required String title,
    required String idLabel,
    required String textKey,
    bool rtl = false,
  }) {
    if (_members.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppTheme.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: AppTheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            ..._members.map((member) {
              final memberId = member[idLabel];
              final text = member[textKey] as String? ?? '';
              if (text.trim().isEmpty) {
                return const SizedBox.shrink();
              }

              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppTheme.background,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppTheme.outline),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        memberId == null ? 'Detail' : '$title $memberId',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: AppTheme.secondary,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        text,
                        textDirection: rtl
                            ? TextDirection.rtl
                            : TextDirection.ltr,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          height: 1.55,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildQuranPassageCard(BuildContext context) {
    final surahName = _surahDisplayName(chunk);
    final ayahCount = _members.isNotEmpty ? _members.length : 1;
    final arabicText = chunk['arabic_text'] as String? ?? '';
    final englishText =
        chunk['english_translation'] as String? ??
        chunk['english_text'] as String? ??
        '';

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              AppTheme.primary.withValues(alpha: 0.08),
              AppTheme.secondary.withValues(alpha: 0.05),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppTheme.primary.withValues(alpha: 0.14)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _ResultBadge(label: surahName.isEmpty ? 'Quran' : surahName),
                const SizedBox(width: 8),
                Text(
                  '$ayahCount ayah${ayahCount == 1 ? '' : 's'}',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: Colors.black.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
            if (englishText.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                englishText,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  height: 1.55,
                  color: AppTheme.textPrimary,
                ),
              ),
            ],
            if (arabicText.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                arabicText,
                textDirection: TextDirection.rtl,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  height: 1.75,
                  color: AppTheme.textPrimary,
                ),
              ),
            ],
            if (_members.isNotEmpty) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.only(top: 12),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: AppTheme.primary.withValues(alpha: 0.12),
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Ayahs',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: AppTheme.primary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    ..._members.asMap().entries.map((entry) {
                      final index = entry.key;
                      final member = entry.value;
                      final ayahId = member['ayah_id'];
                      final memberEnglish =
                          member['english_translation'] as String? ?? '';
                      final memberArabic =
                          member['arabic_text'] as String? ?? '';

                      return Padding(
                        padding: EdgeInsets.only(
                          bottom: index == _members.length - 1 ? 0 : 12,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              ayahId == null ? 'Ayah' : 'Ayah $ayahId',
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color: AppTheme.secondary,
                                  ),
                            ),
                            if (memberEnglish.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                memberEnglish,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      height: 1.45,
                                      color: Colors.black.withValues(
                                        alpha: 0.8,
                                      ),
                                    ),
                              ),
                            ],
                            if (memberArabic.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                memberArabic,
                                textDirection: TextDirection.rtl,
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(
                                      height: 1.7,
                                      color: AppTheme.textPrimary,
                                    ),
                              ),
                            ],
                            if (index != _members.length - 1) ...[
                              const SizedBox(height: 12),
                              Divider(
                                height: 1,
                                thickness: 1,
                                color: AppTheme.outline.withValues(alpha: 0.8),
                              ),
                            ],
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _SearchPageState._sourceLabel(result);
    final reference = _referenceText(result);
    final hasMembers = _members.isNotEmpty;
    final isQuranPassage =
        result.sourceType == 'Quran_Passage' ||
        (result.sourceType.startsWith('Quran') && hasMembers);

    return Container(
      decoration: const BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [AppTheme.background, Colors.white],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 24,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 44,
                          height: 4,
                          decoration: BoxDecoration(
                            color: AppTheme.outline,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        title,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: AppTheme.textPrimary,
                            ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        result.chunkId,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.black.withValues(alpha: 0.6),
                        ),
                      ),
                      if (reference.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          reference,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: AppTheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ],
                      const SizedBox(height: 18),
                      if (isQuranPassage)
                        _buildQuranPassageCard(context)
                      else ...[
                        _buildSection(
                          context,
                          title: 'Arabic text',
                          value: chunk['arabic_text'] as String? ?? '',
                          rtl: true,
                        ),
                        _buildSection(
                          context,
                          title: 'English text',
                          value:
                              chunk['english_text'] as String? ??
                              chunk['english_translation'] as String? ??
                              '',
                        ),
                        if (chunk['arabic_tafsir'] is String &&
                            (chunk['arabic_tafsir'] as String)
                                .trim()
                                .isNotEmpty)
                          _buildSection(
                            context,
                            title: 'Tafsir',
                            value: chunk['arabic_tafsir'] as String? ?? '',
                            rtl: true,
                          ),
                      ],
                      if (result.sourceType == 'Hadith_Cluster')
                        _buildMemberList(
                          context,
                          title: 'Hadith',
                          idLabel: 'hadith_id',
                          textKey: 'english_text',
                        ),
                      if (result.sourceType == 'Hadith')
                        _buildSection(
                          context,
                          title: 'Book',
                          value: chunk['book_name'] as String? ?? '',
                        ),
                      if (result.sourceType == 'Hadith' ||
                          result.sourceType == 'Hadith_Cluster')
                        _buildSection(
                          context,
                          title: 'Chapter',
                          value: chunk['chapter_id']?.toString() ?? '',
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
