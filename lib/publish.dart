import 'models.dart';

enum PublishMode {
  post('Post only'),
  postAndStory('Post + Story'),
  story('Story only');

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
    StepKind.instagramPost => items.length == 1 ? 'Instagram post' : 'Instagram carousel · ${items.length} photos',
    StepKind.instagramStory => 'Instagram story · ${items.single.name}',
    StepKind.facebookPost => items.length == 1 ? 'Facebook post' : 'Facebook post · ${items.length} photos',
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
