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

      // Patch the expected output for known quirks in the YAML -> JSON conversion.
      var expected = t['expected']! as String;
      expected = _patchExpected(filename, t['name']! as String, expected);

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
          expected,
          reason: reason.toString(),
        ),
      );
    }
  });
}

/// Patches the expected output for known quirks in the YAML -> JSON conversion.
String _patchExpected(String filename, String testName, String expected) {
  if (filename == '~inheritance.json' && testName == 'Standalone block') {
    return _patchStandaloneBlockExpected(testName, expected);
  }

  return expected;
}

/// The spec for standalone block is as follows:
/// ```yaml
/// name: Standalone block
/// desc: A block's opening and closing tags need not be on separate lines in order to be standalone
/// data: {}
/// template: |
///   {{<parent}}{{$block}}
///   one
///   two{{/block}}
///   {{/parent}}
/// partials:
///   parent: |
///     Hi,
///       {{$block}}{{/block}}
/// expected: |
///   Hi,
///     one
///     two
/// ```
///
/// The | operator implies a trailing newline on all three multi-line strings, but the expected output
/// should actually end at 'two', without a newline, according to the following rules:
///
/// 1. Text inside a parent tag is ignored (see spec 'text inside parent'), so the newline following
/// {{/block}} in the template should not be rendered.
/// 2. {{/parent}} is a standalone tag per the mustache definition (a tag that appears on a line with
/// only whitespace), and the rendered output should not include any whitespace surrounding it or the
/// newline following it.
/// 3. {{$block}}{{/block}} in the parent partial is a standalone tag per this test, and it should
/// not render any whitespace (except for the indentation required by 'inherit indentation' test),
/// nor the newline following it.
///
/// Therefore, we remove the trailing newline from the expected output.
///
/// The 'standalone parent' test looks very similar to this one, but its parent partial ends with a
/// newline.
String _patchStandaloneBlockExpected(String testName, String expected) {
  if (testName == 'Standalone block') {
    if (expected.endsWith('\n')) {
      return expected.substring(0, expected.length - 1);
    } else {
      throw Exception('Expected output for standalone block test is missing a newline');
    }
  }
  return expected;
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
