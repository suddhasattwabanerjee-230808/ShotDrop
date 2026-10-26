import 'edit/post_shape.dart';
import 'models.dart';

enum PublishMode {
  post('Post Only'),
  postAndStory('Post + Story'),
  story('Story Only');

  const PublishMode(this.label);
  final String label;

  bool get hasPost => this != story;
  bool get hasStory => this != post;
}

enum StepKind { instagramPost, instagramStory, facebookPost }

/// One trip out to Instagram or Facebook: a (carousel) post, or one story.
class PublishStep {
  const PublishStep(this.kind, this.items);
  final StepKind kind;
  final List<UploadItem> items;

  String get title => switch (kind) {
    StepKind.instagramPost => items.length == 1 ? 'Instagram Post' : 'Instagram Carousel · ${items.length} Photos',
    StepKind.instagramStory => 'Instagram Story · ${items.single.name}',
    StepKind.facebookPost => items.length == 1 ? 'Facebook Post' : 'Facebook Post · ${items.length} Photos',
  };
}

/// Instagram takes at most 10 photos in one carousel post.
const carouselMax = 10;

/// The trips needed to post [items] (in posting order) as [mode]: posts
/// first (split into carousels of 10), then one story per photo. With
/// [facebook], each post is also opened in Facebook, for when Instagram's own
/// "share to Facebook" is off.
List<PublishStep> buildPlan(List<UploadItem> items, PublishMode mode, {bool facebook = false}) {
  final steps = <PublishStep>[];
  if (mode.hasPost) {
    for (var i = 0; i < items.length; i += carouselMax) {
      final chunk = items.sublist(i, (i + carouselMax).clamp(0, items.length));
      steps.add(PublishStep(StepKind.instagramPost, chunk));
      if (facebook) steps.add(PublishStep(StepKind.facebookPost, chunk));
    }
  }
  if (mode.hasStory) {
    for (final item in items) {
      steps.add(PublishStep(StepKind.instagramStory, [item]));
    }
  }
  return steps;
}

enum StepStatus { pending, done, later }

/// A round of publishing in progress, kept with the Upload folder so it
/// survives ShotDrop being closed while Instagram is open: which steps went
/// out, which one is next, and how photos are reshaped for posts.
class PublishSession {
  PublishSession({required this.mode, required this.steps, required this.fit, this.keepStoriesForPosts = false, List<StepStatus>? status, this.current = 0})
    : status = status ?? [for (final _ in steps) StepStatus.pending];

  final PublishMode mode;
  final List<PublishStep> steps;
  final List<StepStatus> status;
  final PostFit fit;
  final bool keepStoriesForPosts;
  int current; // the step out in Instagram (or next to go)

  bool get finished => current >= steps.length;
  PublishStep? get step => finished ? null : steps[current];
  PublishStep? get nextStep => current + 1 < steps.length ? steps[current + 1] : null;

  /// Photos whose post or story went out (a Facebook copy doesn't count).
  Set<String> get postedIds => {
    for (var i = 0; i < steps.length; i++)
      if (status[i] == StepStatus.done && steps[i].kind != StepKind.facebookPost)
        for (final item in steps[i].items) item.shotId,
  };

  /// Photos in steps left for later.
  Set<String> get laterIds => {
    for (var i = 0; i < steps.length; i++)
      if (status[i] != StepStatus.done)
        for (final item in steps[i].items) item.shotId,
  }..removeAll(postedIds);

  /// Marks the current step and moves on.
  void resolve(StepStatus s) {
    status[current] = s;
    current++;
  }

  /// Leaves this step and the rest for later.
  void stop() {
    for (var i = current; i < steps.length; i++) {
      status[i] = StepStatus.later;
    }
    current = steps.length;
  }

  /// Replaces the current multi-photo step with one step per photo (the app
  /// wouldn't take several at once).
  void splitCurrent() {
    final s = steps[current];
    steps.replaceRange(current, current + 1, [for (final i in s.items) PublishStep(s.kind, [i])]);
    status.replaceRange(current, current + 1, [for (final _ in s.items) StepStatus.pending]);
  }

  Map<String, Object?> toJson() => {
    'mode': mode.name,
    'fit': fit.name,
    'keepStoriesForPosts': keepStoriesForPosts,
    'current': current,
    'steps': [
      for (final (i, s) in steps.indexed)
        {
          'kind': s.kind.name,
          'items': [for (final item in s.items) item.shotId],
          'status': status[i].name,
        },
    ],
  };

  /// Back from [j], with each step's photos looked up by [item]; photos no
  /// longer there are dropped, and so are steps left empty.
  static PublishSession? fromJson(Map<String, Object?> j, UploadItem? Function(String shotId) item) {
    final steps = <PublishStep>[], status = <StepStatus>[];
    var current = (j['current'] as num?)?.toInt() ?? 0;
    for (final (i, m) in (j['steps'] as List? ?? const []).cast<Map<Object?, Object?>>().indexed) {
      final kind = StepKind.values.asNameMap()[m['kind']];
      final items = [for (final id in (m['items'] as List? ?? const []).cast<String>()) ?item(id)];
      if (kind == null || items.isEmpty) {
        if (i < current) current--;
        continue;
      }
      steps.add(PublishStep(kind, items));
      status.add(StepStatus.values.asNameMap()[m['status']] ?? StepStatus.pending);
    }
    final mode = PublishMode.values.asNameMap()[j['mode']];
    if (mode == null || steps.isEmpty) return null;
    return PublishSession(
      mode: mode,
      steps: steps,
      status: status,
      fit: PostFit.values.asNameMap()[j['fit']] ?? PostFit.crop,
      keepStoriesForPosts: j['keepStoriesForPosts'] == true,
      current: current.clamp(0, steps.length),
    );
  }
}

/// How many of the photos with [aspects] (in posting order; null = not
/// known) get reshaped to go out as posts: each carousel takes its first
/// photo's shape, within Instagram's limits.
int reshapedCount(List<double?> aspects) {
  var n = 0;
  for (var i = 0; i < aspects.length; i += carouselMax) {
    final chunk = aspects.sublist(i, (i + carouselMax).clamp(0, aspects.length));
    final first = chunk.first;
    if (first == null) continue;
    final target = postAspect([first]);
    n += chunk.where((a) => a != null && needsReshape(a, target)).length;
  }
  return n;
}
