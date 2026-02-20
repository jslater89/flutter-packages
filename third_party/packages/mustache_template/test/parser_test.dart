// ignore_for_file: avoid_print

import 'package:mustache_template/src/node.dart';
import 'package:mustache_template/src/parser.dart';
import 'package:mustache_template/src/scanner.dart';
import 'package:mustache_template/src/template_exception.dart';
import 'package:mustache_template/src/token.dart';
import 'package:test/test.dart';

void main() {
  group('Scanner', () {
    test('scan text', () {
      const source = 'abc';
      final scanner = Scanner(source, 'foo', '{{ }}');
      final List<Token> tokens = scanner.scan();
      expectTokens(tokens, <Token>[Token(TokenType.text, 'abc', 0, 3)]);
    });

    test('scan tag', () {
      const source = 'abc{{foo}}def';
      final scanner = Scanner(source, 'foo', '{{ }}');
      final List<Token> tokens = scanner.scan();
      expectTokens(tokens, <Token>[
        Token(TokenType.text, 'abc', 0, 3),
        Token(TokenType.openDelimiter, '{{', 3, 5),
        Token(TokenType.identifier, 'foo', 5, 8),
        Token(TokenType.closeDelimiter, '}}', 8, 10),
        Token(TokenType.text, 'def', 10, 13),
      ]);
    });

    test('scan tag whitespace', () {
      const source = 'abc{{ foo }}def';
      final scanner = Scanner(source, 'foo', '{{ }}');
      final List<Token> tokens = scanner.scan();
      expectTokens(tokens, <Token>[
        Token(TokenType.text, 'abc', 0, 3),
        Token(TokenType.openDelimiter, '{{', 3, 5),
        Token(TokenType.whitespace, ' ', 5, 6),
        Token(TokenType.identifier, 'foo', 6, 9),
        Token(TokenType.whitespace, ' ', 9, 10),
        Token(TokenType.closeDelimiter, '}}', 10, 12),
        Token(TokenType.text, 'def', 12, 15),
      ]);
    });

    test('scan tag sigil', () {
      const source = 'abc{{ # foo }}def';
      final scanner = Scanner(source, 'foo', '{{ }}');
      final List<Token> tokens = scanner.scan();
      expectTokens(tokens, <Token>[
        Token(TokenType.text, 'abc', 0, 3),
        Token(TokenType.openDelimiter, '{{', 3, 5),
        Token(TokenType.whitespace, ' ', 5, 6),
        Token(TokenType.sigil, '#', 6, 7),
        Token(TokenType.whitespace, ' ', 7, 8),
        Token(TokenType.identifier, 'foo', 8, 11),
        Token(TokenType.whitespace, ' ', 11, 12),
        Token(TokenType.closeDelimiter, '}}', 12, 14),
        Token(TokenType.text, 'def', 14, 17),
      ]);
    });

    test('scan tag dot', () {
      const source = 'abc{{ foo.bar }}def';
      final scanner = Scanner(source, 'foo', '{{ }}');
      final List<Token> tokens = scanner.scan();
      expectTokens(tokens, <Token>[
        Token(TokenType.text, 'abc', 0, 3),
        Token(TokenType.openDelimiter, '{{', 3, 5),
        Token(TokenType.whitespace, ' ', 5, 6),
        Token(TokenType.identifier, 'foo', 6, 9),
        Token(TokenType.dot, '.', 9, 10),
        Token(TokenType.identifier, 'bar', 10, 13),
        Token(TokenType.whitespace, ' ', 13, 14),
        Token(TokenType.closeDelimiter, '}}', 14, 16),
        Token(TokenType.text, 'def', 16, 19),
      ]);
    });

    test('scan triple mustache', () {
      const source = 'abc{{{foo}}}def';
      final scanner = Scanner(source, 'foo', '{{ }}');
      final List<Token> tokens = scanner.scan();
      expectTokens(tokens, <Token>[
        Token(TokenType.text, 'abc', 0, 3),
        Token(TokenType.openDelimiter, '{{{', 3, 6),
        Token(TokenType.identifier, 'foo', 6, 9),
        Token(TokenType.closeDelimiter, '}}}', 9, 12),
        Token(TokenType.text, 'def', 12, 15),
      ]);
    });

    test('scan triple mustache whitespace', () {
      const source = 'abc{{{ foo }}}def';
      final scanner = Scanner(source, 'foo', '{{ }}');
      final List<Token> tokens = scanner.scan();
      expectTokens(tokens, <Token>[
        Token(TokenType.text, 'abc', 0, 3),
        Token(TokenType.openDelimiter, '{{{', 3, 6),
        Token(TokenType.whitespace, ' ', 6, 7),
        Token(TokenType.identifier, 'foo', 7, 10),
        Token(TokenType.whitespace, ' ', 10, 11),
        Token(TokenType.closeDelimiter, '}}}', 11, 14),
        Token(TokenType.text, 'def', 14, 17),
      ]);
    });

    test('scan tag with equals', () {
      const source = '{{foo=bar}}';
      final scanner = Scanner(source, 'foo', '{{ }}');
      final List<Token> tokens = scanner.scan();
      expectTokens(tokens, <Token>[
        Token(TokenType.openDelimiter, '{{', 0, 2),
        Token(TokenType.identifier, 'foo=bar', 2, 9),
        Token(TokenType.closeDelimiter, '}}', 9, 11),
      ]);
    });

    test('scan comment with equals', () {
      const source = '{{!foo=bar}}';
      final scanner = Scanner(source, 'foo', '{{ }}');
      final List<Token> tokens = scanner.scan();
      expectTokens(tokens, <Token>[
        Token(TokenType.openDelimiter, '{{', 0, 2),
        Token(TokenType.sigil, '!', 2, 3),
        Token(TokenType.identifier, 'foo=bar', 3, 10),
        Token(TokenType.closeDelimiter, '}}', 10, 12),
      ]);
    });
  });

  group('Parser', () {
    test('parse variable', () {
      const source = 'abc{{foo}}def';
      final parser = Parser(source, 'foo', '{{ }}');
      final List<Node> nodes = parser.parse();
      expectNodes(nodes, <Node>[
        TextNode('abc', 0, 3, null),
        VariableNode('foo', 3, 10, null),
        TextNode('def', 10, 13, null),
      ]);
    });

    test('parse variable whitespace', () {
      const source = 'abc{{ foo }}def';
      final parser = Parser(source, 'foo', '{{ }}');
      final List<Node> nodes = parser.parse();
      expectNodes(nodes, <Node>[
        TextNode('abc', 0, 3, null),
        VariableNode('foo', 3, 12, null),
        TextNode('def', 12, 15, null),
      ]);
    });

    test('parse section', () {
      const source = 'abc{{#foo}}def{{/foo}}ghi';
      final parser = Parser(source, 'foo', '{{ }}');
      final List<Node> nodes = parser.parse();
      expectNodes(nodes, <Node>[
        TextNode('abc', 0, 3, null),
        SectionNode('foo', 3, 11, null, '{{ }}'),
        TextNode('ghi', 22, 25, null),
      ]);
      expectNodes((nodes[1] as SectionNode).children, <Node>[
        TextNode('def', 11, 14, null),
      ]);
    });

    test('parse section standalone tag whitespace', () {
      const source = 'abc\n{{#foo}}\ndef\n{{/foo}}\nghi';
      final parser = Parser(source, 'foo', '{{ }}');
      final List<Node> nodes = parser.parse();
      expectNodes(nodes, <Node>[
        TextNode('abc\n', 0, 4, null),
        SectionNode('foo', 4, 12, null, '{{ }}'),
        TextNode('ghi', 26, 29, null),
      ]);
      expectNodes((nodes[1] as SectionNode).children, <Node>[
        TextNode('def\n', 13, 17, null),
      ]);
    });

    test('parse section standalone tag whitespace consecutive', () {
      const source =
          'abc\n{{#foo}}\ndef\n{{/foo}}\n{{#foo}}\ndef\n{{/foo}}\nghi';
      final parser = Parser(source, 'foo', '{{ }}');
      final List<Node> nodes = parser.parse();
      expectNodes(nodes, <Node>[
        TextNode('abc\n', 0, 4, null),
        SectionNode('foo', 4, 12, null, '{{ }}'),
        SectionNode('foo', 26, 34, null, '{{ }}'),
        TextNode('ghi', 48, 51, null),
      ]);
      expectNodes((nodes[1] as SectionNode).children, <Node>[
        TextNode('def\n', 13, 17, null),
      ]);
    });

    test('parse section standalone tag whitespace on first line', () {
      const source = '  {{#foo}}  \ndef\n{{/foo}}\nghi';
      final parser = Parser(source, 'foo', '{{ }}');
      final List<Node> nodes = parser.parse();
      expectNodes(nodes, <Node>[
        SectionNode('foo', 2, 10, null, '{{ }}'),
        TextNode('ghi', 26, 29, null),
      ]);
      expectNodes((nodes[0] as SectionNode).children, <Node>[
        TextNode('def\n', 13, 17, null),
      ]);
    });

    test('parse section standalone tag whitespace on last line', () {
      const source = '{{#foo}}def\n  {{/foo}}  ';
      final parser = Parser(source, 'foo', '{{ }}');
      final List<Node> nodes = parser.parse();
      expectNodes(nodes, <Node>[SectionNode('foo', 0, 8, null, '{{ }}')]);
      expectNodes((nodes[0] as SectionNode).children, <Node>[
        TextNode('def\n', 8, 12, null),
      ]);
    });

    test('parse variable newline', () {
      const source = 'abc\n\n{{foo}}def';
      final parser = Parser(source, 'foo', '{{ }}');
      final List<Node> nodes = parser.parse();
      expectNodes(nodes, <Node>[
        TextNode('abc\n\n', 0, 5, null),
        VariableNode('foo', 5, 12, null),
        TextNode('def', 12, 15, null),
      ]);
    });

    test('parse section standalone tag whitespace v2', () {
      const source = 'abc\n\n{{#foo}}\ndef\n{{/foo}}\nghi';
      final parser = Parser(source, 'foo', '{{ }}');
      final List<Node> nodes = parser.parse();
      expectNodes(nodes, <Node>[
        TextNode('abc\n\n', 0, 5, null),
        SectionNode('foo', 5, 13, null, '{{ }}'),
        TextNode('ghi', 27, 30, null),
      ]);
      expectNodes((nodes[1] as SectionNode).children, <Node>[
        TextNode('def\n', 14, 18, null),
      ]);
    });

    test('parse whitespace', () {
      const source = 'abc\n   ';
      final parser = Parser(source, 'foo', '{{ }}');
      final List<Node> nodes = parser.parse();
      expectNodes(nodes, <Node>[TextNode('abc\n   ', 0, 7, null)]);
    });

    test('parse partial', () {
      const source = 'abc\n   {{>foo}}def';
      final parser = Parser(source, 'foo', '{{ }}');
      final List<Node> nodes = parser.parse();
      expectNodes(nodes, <Node>[
        TextNode('abc\n   ', 0, 7, null),
        PartialNode('foo', 7, 15, '   ', null),
        TextNode('def', 15, 18, null),
      ]);
    });

    test('parse change delimiters', () {
      const source = '{{= | | =}}<|#lambda|-|/lambda|>';
      final parser = Parser(source, 'foo', '{{ }}');
      final List<Node> nodes = parser.parse();
      expectNodes(nodes, <Node>[
        TextNode('<', 11, 12, null),
        SectionNode('lambda', 12, 21, null, '| |'),
        TextNode('>', 31, 32, null),
      ]);
      expect((nodes[1] as SectionNode).delimiters, equals('| |'));
      expectNodes((nodes[1] as SectionNode).children, <Node>[
        TextNode('-', 21, 22, null),
      ]);
    });

    test('corner case strict', () {
      const source = '{{{ #foo }}} {{{ /foo }}}';
      final parser = Parser(source, 'foo', '{{ }}');
      try {
        parser.parse();
        // TODO(stuartmorgan): Restructure test to use throwsA.
        // ignore: use_test_throws_matchers
        fail('Should fail.');
      } on Exception catch (e) {
        expect(e is TemplateException, isTrue);
      }
    });

    test('corner case lenient', () {
      const source = '{{{ #foo }}} {{{ /foo }}}';
      final parser = Parser(source, 'foo', '{{ }}', lenient: true);
      final List<Node> nodes = parser.parse();
      expectNodes(nodes, <Node>[
        VariableNode('#foo', 0, 12, null, escape: false),
        TextNode(' ', 12, 13, null),
        VariableNode('/foo', 13, 25, null, escape: false),
      ]);
    });

    test('emoji', () {
      const source = 'Hello! 🖖👍🏽🏳️‍🌈\nEmoji';
      final parser = Parser(source, 'foo', '{{ }}');
      final List<Node> nodes = parser.parse();
      // End offset includes emoji sizes
      expectNodes(nodes, <Node>[TextNode('Hello! 🖖👍🏽🏳️‍🌈\nEmoji', 0, 20, null)]);
    });

    test('parent tag pair clearance', () {
      const source = r'{{<parent}}{{$block}}default{{/block}}{{/parent}}';
      final parser = Parser(source, 'foo', '{{ }}');
      final List<Node> nodes = parser.parse();
      expect(nodes[0], isA<ParentNode>());

      final parent = nodes[0] as ParentNode;
      expect(parent.startClearLeft, isTrue);
      expect(parent.endClearRight, isTrue);
      expect(parent.startClearRight, isFalse);
      expect(parent.endClearLeft, isFalse);
      expect(parent.isContainerStandalone, isTrue);
    });

    test('argument block detection', () {
      const source = r'{{<parent}}{{$block}}default{{/block}}{{/parent}}';
      final parser = Parser(source, 'foo', '{{ }}');
      final List<Node> nodes = parser.parse();
      expect(nodes[0], isA<ParentNode>());
      final parent = nodes[0] as ParentNode;

      expect(parent.children[0], isA<BlockNode>());
      final block = parent.children[0] as BlockNode;
      expect(block.isArgument, isTrue);
    });

    test('nested argument block detection', () {
      const source = r'{{<parent}}{{#section}}{{$block}}positive content{{/block}}{{/section}}{{/parent}}';
      final parser = Parser(source, 'foo', '{{ }}');
      final List<Node> nodes = parser.parse();
      expect(nodes[0], isA<ParentNode>());
      final parent = nodes[0] as ParentNode;
      expect(parent.children[0], isA<SectionNode>());
      final section = parent.children[0] as SectionNode;
      expect(section.children[0], isA<BlockNode>());
      final block = section.children[0] as BlockNode;
      expect(block.isArgument, isTrue);
    });

    test('parameter block detection', () {
      const source = r'{{#section}}{{$block}}default{{/block}}{{/section}}';
      final parser = Parser(source, 'foo', '{{ }}');
      final List<Node> nodes = parser.parse();
      expect(nodes[0], isA<SectionNode>());
      final section = nodes[0] as SectionNode;
      expect(section.children[0], isA<BlockNode>());
      final block = section.children[0] as BlockNode;
      expect(block.isParameter, isTrue);
    });

    test('inline block tag clearance with default', () {
      const source = r'{{<parent}}{{$block}}default{{/block}}{{/parent}}';
      final parser = Parser(source, 'foo', '{{ }}');
      final List<Node> nodes = parser.parse();
      expect(nodes[0], isA<ParentNode>());
      final parent = nodes[0] as ParentNode;

      expect(parent.children[0], isA<BlockNode>());
      final block = parent.children[0] as BlockNode;
      expect(block.startClearLeft, isFalse);
      expect(block.startClearRight, isFalse);
      expect(block.endClearLeft, isFalse);
      expect(block.endClearRight, isFalse);
      expect(block.isContainerStandalone, isFalse);
      expect(block.isInnerStandalone, isFalse);
      expect(block.isStartStandalone, isFalse);
      expect(block.isEndStandalone, isFalse);
     });

     test('inline block tag with no default content', () {
      const source = r'{{<parent}}{{$block}}{{/block}}{{/parent}}';
      final parser = Parser(source, 'foo', '{{ }}');
      final List<Node> nodes = parser.parse();
      expect(nodes[0], isA<ParentNode>());
      final parent = nodes[0] as ParentNode;

      expect(parent.children[0], isA<BlockNode>());
      final block = parent.children[0] as BlockNode;
      expect(block.startClearLeft, isFalse);
      expect(block.startClearRight, isFalse);
      expect(block.endClearLeft, isFalse);
      expect(block.endClearRight, isFalse);
      expect(block.isContainerStandalone, isFalse);
      expect(block.isInnerStandalone, isFalse);
      expect(block.isStartStandalone, isFalse);
      expect(block.isEndStandalone, isFalse);
     });

     test('multiline parent/block tag clearance with default', () {
      const source = '{{<parent}}{{\$block}}\ndefault\n{{/block}}{{/parent}}';
      final parser = Parser(source, 'foo', '{{ }}');
      final List<Node> nodes = parser.parse();
      expect(nodes[0], isA<ParentNode>());
      final parent = nodes[0] as ParentNode;
      expect(parent.startClearLeft, isTrue);
      expect(parent.startClearRight, isFalse);
      expect(parent.endClearLeft, isFalse);
      expect(parent.endClearRight, isTrue);
      expect(parent.isContainerStandalone, isTrue);

      expect(parent.children[0], isA<BlockNode>());
      final block = parent.children[0] as BlockNode;
      expect(block.startClearLeft, isFalse);
      expect(block.startClearRight, isTrue);
      expect(block.endClearLeft, isTrue);
      expect(block.endClearRight, isFalse);
      expect(block.isContainerStandalone, isFalse);
      expect(block.isInnerStandalone, isTrue);
     });

    test('toString', () {
      TextNode('foo', 1, 3, null).toString();
      VariableNode('foo', 1, 3, null).toString();
      PartialNode('foo', 1, 3, ' ', null).toString();
      SectionNode('foo', 1, 3, null, '{{ }}').toString();
      Token(TokenType.closeDelimiter, 'foo', 1, 3).toString();
      TokenType.closeDelimiter.toString();
    });

    test('exception', () {
      const source =
          "'{{ foo }} sdfffffffffffffffffffffffffffffffffffffffffffff "
          'dsfsdf sdfdsa fdsfads fsdfdsfadsf dsfasdfsdf sdfdsfsadf sdfadsfsdf ';
      final ex = TemplateException('boom!', 'foo.mustache', source, 2);
      ex.toString();
    });

    Exception parseFail(String source) {
      try {
        final parser = Parser(source, 'foo', '{{ }}');
        parser.parse();
        // TODO(stuartmorgan): Restructure test to use throwsA.
        // ignore: use_test_throws_matchers
        fail('Did not throw.');
      } on Exception catch (ex, st) {
        if (ex is! TemplateException) {
          print(ex);
          print(st);
        }
        return ex;
      }
    }

    test('parse eof', () {
      void expectTemplateEx(Exception ex) =>
          expect(ex is TemplateException, isTrue);

      expectTemplateEx(parseFail('{{#foo}}{{bar}}{{/foo}'));
      expectTemplateEx(parseFail('{{#foo}}{{bar}}{{/foo'));
      expectTemplateEx(parseFail('{{#foo}}{{bar}}{{/'));
      expectTemplateEx(parseFail('{{#foo}}{{bar}}{{'));
      expectTemplateEx(parseFail('{{#foo}}{{bar}}{'));
      expectTemplateEx(parseFail('{{#foo}}{{bar}}'));
      expectTemplateEx(parseFail('{{#foo}}{{bar}'));
      expectTemplateEx(parseFail('{{#foo}}{{bar'));
      expectTemplateEx(parseFail('{{#foo}}{{'));
      expectTemplateEx(parseFail('{{#foo}}{'));
      expectTemplateEx(parseFail('{{#foo}}'));
      expectTemplateEx(parseFail('{{#foo}'));
      expectTemplateEx(parseFail('{{#'));
      expectTemplateEx(parseFail('{{'));
      expectTemplateEx(parseFail('{{ # foo }}{{ bar }}{{ / foo }'));
      expectTemplateEx(parseFail('{{ # foo }}{{ bar }}{{ / foo '));
      expectTemplateEx(parseFail('{{ # foo }}{{ bar }}{{ / foo'));
      expectTemplateEx(parseFail('{{ # foo }}{{ bar }}{{ / '));
      expectTemplateEx(parseFail('{{ # foo }}{{ bar }}{{ /'));
      expectTemplateEx(parseFail('{{ # foo }}{{ bar }}{{ '));
      expectTemplateEx(parseFail('{{ # foo }}{{ bar }}{{'));
      expectTemplateEx(parseFail('{{ # foo }}{{ bar }}{'));
      expectTemplateEx(parseFail('{{ # foo }}{{ bar }}'));
      expectTemplateEx(parseFail('{{ # foo }}{{ bar }'));
      expectTemplateEx(parseFail('{{ # foo }}{{ bar '));
      expectTemplateEx(parseFail('{{ # foo }}{{ bar'));
      expectTemplateEx(parseFail('{{ # foo }}{{ '));
      expectTemplateEx(parseFail('{{ # foo }}{{'));
      expectTemplateEx(parseFail('{{ # foo }}{'));
      expectTemplateEx(parseFail('{{ # foo }}'));
      expectTemplateEx(parseFail('{{ # foo }'));
      expectTemplateEx(parseFail('{{ # foo '));
      expectTemplateEx(parseFail('{{ # foo'));
      expectTemplateEx(parseFail('{{ # '));
      expectTemplateEx(parseFail('{{ #'));
      expectTemplateEx(parseFail('{{ '));
      expectTemplateEx(parseFail('{{'));

      expectTemplateEx(parseFail('{{= || || =}'));
      expectTemplateEx(parseFail('{{= || || ='));
      expectTemplateEx(parseFail('{{= || || '));
      expectTemplateEx(parseFail('{{= || ||'));
      expectTemplateEx(parseFail('{{= || |'));
      expectTemplateEx(parseFail('{{= || '));
      expectTemplateEx(parseFail('{{= ||'));
      expectTemplateEx(parseFail('{{= |'));
      expectTemplateEx(parseFail('{{= '));
      expectTemplateEx(parseFail('{{='));
    });
  });
}

bool nodeEqual(Node a, Node b) {
  if (a is TextNode) {
    return b is TextNode &&
        a.text == b.text &&
        a.start == b.start &&
        a.end == b.end;
  } else if (a is VariableNode && b is VariableNode) {
    return a.name == b.name &&
        a.escape == b.escape &&
        a.start == b.start &&
        a.end == b.end;
  } else if (a is SectionNode && b is SectionNode) {
    return a.name == b.name &&
        a.delimiters == b.delimiters &&
        a.inverse == b.inverse &&
        a.start == b.start &&
        a.end == b.end;
  } else if (a is PartialNode && b is PartialNode) {
    return a.name == b.name && a.indent == b.indent;
  } else {
    return false;
  }
}

bool tokenEqual(Token a, Token b) {
  return a.type == b.type &&
      a.value == b.value &&
      a.start == b.start &&
      a.end == b.end;
}

void expectTokens(List<Token> a, List<Token> b) {
  expect(a.length, equals(b.length), reason: '$a != $b');
  for (var i = 0; i < a.length; i++) {
    expect(tokenEqual(a[i], b[i]), isTrue, reason: '$a != $b');
  }
}

void expectNodes(List<Node> a, List<Node> b) {
  expect(a.length, equals(b.length), reason: '$a != $b');
  for (var i = 0; i < a.length; i++) {
    expect(nodeEqual(a[i], b[i]), isTrue, reason: '$a != $b');
  }
}
