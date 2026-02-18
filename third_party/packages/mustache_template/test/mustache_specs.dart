// Specification files can be downloaded here https://github.com/mustache/spec

// Test implemented by Georgios Valotasios.
// See: https://github.com/valotas/mustache4dart

import 'dart:convert';
import 'dart:io';

import 'package:mustache_template/mustache.dart';
import 'package:test/test.dart';

String render(
  String source,
  dynamic values, {
  required String? Function(String) partial,
}) {
  late Template? Function(String) resolver;
  resolver = (String name) {
    final String? source = partial(name);
    if (source == null) {
      return null;
    }
    return Template(source, partialResolver: resolver, lenient: true);
  };
  final t = Template(source, partialResolver: resolver, lenient: true);
  return t.renderString(values);
}

void defineTests(List<String> unsupportedSpecs) {
  final specsDir = Directory('test/specs');
  specsDir.listSync().forEach((FileSystemEntity f) {
    if (f is File) {
      final String filename = f.path;
      if (shouldRun(filename, unsupportedSpecs)) {
        final String text = f.readAsStringSync();
        _defineGroupFromFile(filename, text);
      }
    }
  });
}

void _defineGroupFromFile(String filename, String text) {
  final Map<String, Object?> jsondata =
      (json.decode(text) as Map<dynamic, dynamic>).cast<String, Object?>();
  final List<Map<String, Object?>> tests = (jsondata['tests']! as List<dynamic>)
      .cast<Map<String, Object?>>();
  filename = filename.substring(filename.lastIndexOf('/') + 1);
  group('Specs of $filename', () {
    for (final t in tests) {
      final testDescription = StringBuffer(t['name']! as String);
      testDescription.write(': ');
      testDescription.write(t['desc']);
      final template = t['template']! as String;
      final Object? data = t['data'];
      final String templateOneline = template
          .replaceAll('\n', r'\n')
          .replaceAll('\r', r'\r');
      final reason = StringBuffer(
        "Could not render right '''$templateOneline'''",
      );
      final Object? expected = t['expected'];
      final partials = t['partials'] as Map<String, Object?>?;
      String? partial(String name) {
        if (partials == null) {
          return null;
        }
        return partials[name] as String?;
      }

      //swap the data.lambda with a dart real function
      if (data is Map && data['lambda'] != null) {
        data['lambda'] = lambdas[t['name']];
      }
      reason.write(" with '$data'");
      if (partials != null) {
        reason.write(' and partial: $partials');
      }
      test(
        testDescription.toString(),
        () => expect(
          render(template, data, partial: partial),
          OutputMatcher(expected),
          reason: reason.toString(),
        ),
      );
    }
  });
}

/// A matcher that handles a quirk in mustache spec YAML -> JSON conversion,
/// which causes correctly-implemented mustache implementations to insert
/// extra newlines when rendering templates from the JSON version of the spec.
///
/// Consider this YAML specification block (~inheritance/Block reindentation):
/// ```yaml
///    template: |
///      {{<parent}}{{$block}}
///          one
///          two
///      {{/block}}{{/parent}}
///    partials:
///      parent: |
///        Hi,
///          {{$block}}
///          {{/block}}
///    expected: |
///      Hi,
///        one
///        two
/// ```
///
/// And the corresponding generated JSON:
/// ```json
///     {
///       "template": "{{<parent}}{{$block}}\n    one\n    two\n{{/block}}{{/parent}}\n",
///       "partials": {
///         "parent": "Hi,\n  {{$block}}\n  {{/block}}\n",
///       },
///       "expected": "Hi,\n  one\n  two\n",
///     }
/// ```
///
/// The conversion to JSON introduces a newline at the end of every multi-line YAML string:
/// one each at the end of the parent partial, the template, and the expected output. However,
/// since the rendered output ends with the end of the parent partial, we get two newlines at
/// the end of the rendered output vs. one at the end of the expected output.
///
/// There is a second case which only occurs once in the specs (~inheritance/Inherit):
///
/// ```yaml
///    template: |
///      {{<include}}{{/include}}
///    partials:
///      include: "{{$foo}}default content{{/foo}}"
///    expected: "default content"
/// ```
///
/// In this case, the expected output is "default content", but the generated JSON includes
/// a newline at the end of the expected multi-line template. This matcher handles this case by stripping
/// the newline from the expected output if it exists.
///
/// To handle both cases, the matchers allows an extra newline at the end of the rendered output
/// if:
///   1. The rendered output ends in two newlines and the expected output ends in one newline
///   2. The rendered output ends in one newline and the expected output ends in no newline
///
/// Because the mustache specs are written in a variety of styles (some define template, partials,
/// and expected output as multi-line strings only, some use quoted single-line strings only, and
/// others mix and match), and the JSON output doesn't include any information about whether the
/// YAML strings were single-line or multi-line, and further, some of the single-line quoted strings
/// end in \n newlines, there is no easy solution on the specification parsing side to handle this—
/// simple solutions like stripping newlines from everything will break other known-working tests.
class OutputMatcher extends Matcher {
  OutputMatcher(this.expected) : outputMatcher = equals(expected);

  late final Matcher outputMatcher;
  final Object? expected;

  @override
  Description describe(Description description) {
    return outputMatcher.describe(description);
  }

  @override
  bool matches(Object? item, Map<dynamic, dynamic> matchState) {
    final bool equalsExactly = outputMatcher.matches(item, matchState);
    if (equalsExactly) {
      return true;
    }

    // The YAML -> JSON conversion for specs is lossy (per mustache docs). In particular,
    // YAML multi-line strings are always rendered as JSON strings ending in \n. So, if
    // we have a template given in a YAML multi-line string, the generated JSON includes
    // a newline at the end of the template.

    if(expected is String? && item is String) {
      final expectedString = expected as String?;
      if(expectedString != null) {
        if (expectedString.endsWith('\n') && item.endsWith('\n\n')) {
          item = item.substring(0, item.length - 1);
        } else if (!expectedString.endsWith('\n') && item.endsWith('\n')) {
          item = item.substring(0, item.length - 1);
        }
      }
    }

    return outputMatcher.matches(item, matchState);
  }
}

bool shouldRun(String filename, List<String> unsupportedSpecs) {
  // filter out only .json files
  if (!filename.endsWith('.json')) {
    return false;
  }
  final String specName = filename.substring(filename.lastIndexOf('/') + 1).replaceFirst('.json', '');
  return !unsupportedSpecs.contains(specName);
}

String Function(Object?) _dummyCallableWithState() {
  var callCounter = 0;
  return (Object? arg) {
    callCounter++;
    return callCounter.toString();
  };
}

String Function(LambdaContext) wrapLambda(Object? Function(Object?) f) =>
    (LambdaContext ctx) => ctx.renderSource(f(ctx.source).toString());

Map<String, Function> lambdas = <String, Function>{
  'Interpolation': wrapLambda((Object? t) => 'world'),
  'Interpolation - Expansion': wrapLambda((Object? t) => '{{planet}}'),
  'Interpolation - Alternate Delimiters': wrapLambda(
    (Object? t) => '|planet| => {{planet}}',
  ),
  'Interpolation - Multiple Calls': wrapLambda(
    _dummyCallableWithState(),
  ), //function() { return (g=(function(){return this})()).calls=(g.calls||0)+1 }
  'Escaping': wrapLambda((Object? t) => '>'),
  'Section': wrapLambda((Object? txt) => txt == '{{x}}' ? 'yes' : 'no'),
  'Section - Expansion': wrapLambda((Object? txt) => '$txt{{planet}}$txt'),
  'Section - Alternate Delimiters': wrapLambda(
    (Object? txt) => '$txt{{planet}} => |planet|$txt',
  ),
  'Section - Multiple Calls': wrapLambda((Object? t) => '__${t}__'),
  'Inverted Section': wrapLambda((Object? txt) => false),
};
