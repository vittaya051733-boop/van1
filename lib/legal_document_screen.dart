import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'data/legal_content.dart';

class LegalDocumentScreen extends StatelessWidget {
  const LegalDocumentScreen({super.key, required this.document});

  final LegalDocument document;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(document.titleTh),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: <Widget>[
          Text(
            'อัปเดตครั้งล่าสุด: ${document.updatedAtLabel}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFF6B7280),
              fontWeight: FontWeight.w600,
            ),
          ),
          if (document.publicUrl != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () {
                  final uri = Uri.tryParse(document.publicUrl!);
                  if (uri == null) return;
                  launchUrl(uri, mode: LaunchMode.externalApplication);
                },
                child: const Text('เปิดบนเว็บ'),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            document.bodyTh,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              height: 1.55,
              color: const Color(0xFF374151),
            ),
          ),
        ],
      ),
    );
  }
}
