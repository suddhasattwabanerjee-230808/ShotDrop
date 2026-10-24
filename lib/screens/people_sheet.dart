import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../faces.dart';
import '../models.dart';
import '../theme.dart';

/// The People filter: everyone ShotDrop has found in this gallery's photos,
/// as round faces with how many photos each is in. Faces are still being
/// looked for while it's open, and people turn up as they're found. Pops the
/// [Person.id] picked.
class PeopleSheet extends StatelessWidget {
  const PeopleSheet({super.key, required this.shots, this.current});
  final List<CardShot> shots; // every photo in the gallery
  final String? current;

  @override
  Widget build(BuildContext context) {
    final index = FaceIndex.instance;
    return ListenableBuilder(
      listenable: index,
      builder: (context, _) {
        final keys = {
          for (final s in shots)
            if (s.jpg case final f?) FaceIndex.keyOf(f),
        };
        final people = [
          for (final p in index.people)
            if (p.photos.where(keys.contains).length case final n when n > 0) (person: p, count: n),
        ]..sort((a, b) => b.count.compareTo(a.count));
        final left = index.remaining(shots);
        final total = keys.length;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('People', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(
                    people.isEmpty ? 'Faces Found In Your Photos' : 'Tap Someone To See Only Their Photos',
                    style: TextStyle(fontSize: 13, color: muted, fontWeight: FontWeight.w600),
                  ),
                  if (left > 0) ...[const SizedBox(height: 14), _Progress(done: total - left, total: total)],
                  const SizedBox(height: 16),
                  if (people.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Row(
                        children: [
                          Icon(Icons.face_retouching_off_rounded, size: 36, color: muted),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              left > 0
                                  ? 'People show up here as their faces are found. Someone needs to be in two photos or more.'
                                  : 'Nobody turns up in two photos or more here yet.',
                              style: TextStyle(color: muted, fontWeight: FontWeight.w600, height: 1.35),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    Flexible(
                      child: GridView.builder(
                        shrinkWrap: true,
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 104,
                          mainAxisSpacing: 14,
                          crossAxisSpacing: 10,
                          childAspectRatio: 0.74,
                        ),
                        itemCount: people.length,
                        itemBuilder: (context, i) {
                          final (:person, :count) = people[i];
                          return _PersonBubble(
                            person: person,
                            count: count,
                            ring: rainbow[i % rainbow.length],
                            picked: person.id == current,
                            onTap: () {
                              HapticFeedback.selectionClick();
                              Navigator.pop(context, person.id);
                            },
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(Icons.lock_rounded, size: 14, color: muted),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Found On This Phone. No Photo Leaves It.',
                          style: TextStyle(fontSize: 12, color: muted, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.done, required this.total});
  final int done, total;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
    decoration: BoxDecoration(color: surfaceHigh, borderRadius: BorderRadius.circular(16)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: accent)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Looking For Faces… $done Of $total',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: total == 0 ? null : done / total,
            minHeight: 8,
            color: accent,
            backgroundColor: line,
          ),
        ),
      ],
    ),
  );
}

class _PersonBubble extends StatelessWidget {
  const _PersonBubble({
    required this.person,
    required this.count,
    required this.ring,
    required this.picked,
    required this.onTap,
  });

  final Person person;
  final int count;
  final Color ring;
  final bool picked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(20),
    child: Column(
      children: [
        Expanded(
          child: AspectRatio(
            aspectRatio: 1,
            child: Container(
              padding: EdgeInsets.all(picked ? 4 : 3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: picked ? accent : ring,
                boxShadow: [BoxShadow(color: deeper(picked ? accent : ring, 0.18), offset: const Offset(0, 4))],
              ),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(shape: BoxShape.circle, color: surface),
                child: ClipOval(child: FaceAvatar(person: person)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          count == 1 ? '1 Photo' : '$count Photos',
          maxLines: 1,
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: picked ? accent : ink),
        ),
      ],
    ),
  );
}

/// [person]'s face, filling a square.
class FaceAvatar extends StatelessWidget {
  const FaceAvatar({super.key, required this.person});
  final Person person;

  @override
  Widget build(BuildContext context) => Image.file(
    File(person.cover),
    fit: BoxFit.cover,
    width: double.infinity,
    height: double.infinity,
    cacheWidth: 200,
    gaplessPlayback: true,
    errorBuilder: (_, _, _) => ColoredBox(
      color: surfaceHigh,
      child: Icon(Icons.face_rounded, color: muted),
    ),
  );
}
