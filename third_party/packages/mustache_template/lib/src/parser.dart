// TODO(stuartmorgan): Remove this. See https://github.com/flutter/flutter/issues/174722.
// ignore_for_file: public_member_api_docs

import 'node.dart';
import 'scanner.dart';
import 'template_exception.dart';
import 'token.dart';

List<Node> parse(
  String source,
  bool lenient,
  String? templateName,
  String delimiters,
) {
  final parser = Parser(source, templateName, delimiters, lenient: lenient);
  return parser.parse();
}

class Tag {
  Tag(this.type, this.name, this.start, this.end);
  final TagType type;
  final String name;
  final int start;
  final int end;
}

class TagType {
  const TagType(this.name, {this.opensContainer = false});
  final String name;
  final bool opensContainer;

  static const TagType openSection = TagType('openSection', opensContainer: true);
  static const TagType openInverseSection = TagType('openInverseSection', opensContainer: true);
  static const TagType closeSection = TagType('closeSection');
  static const TagType variable = TagType('variable');
  static const TagType tripleMustache = TagType('tripleMustache');
  static const TagType unescapedVariable = TagType('unescapedVariable');
  static const TagType partial = TagType('partial');
  static const TagType comment = TagType('comment');
  static const TagType changeDelimiter = TagType('changeDelimiter');
  static const TagType openParent = TagType('openParent', opensContainer: true);
  static const TagType openBlock = TagType('openBlock', opensContainer: true);
}

class Parser {
  Parser(
    String source,
    String? templateName,
    String delimiters, {
    bool lenient = false,
  }) : _source = source,
       _templateName = templateName,
       _delimiters = delimiters,
       _lenient = lenient,
       _scanner = Scanner(source, templateName, delimiters);

  final String _source;
  final bool _lenient;
  final String? _templateName;
  final String _delimiters;
  final Scanner _scanner;
  final List<ContainerNode> _stack = <ContainerNode>[];
  late List<Token> _tokens;
  late String _currentDelimiters;
  int _offset = 0;

  /// Whitespace before a block or parent tag at line start becomes that tag's indent.
  String? _pendingWhitespace;
  bool _afterLineEnd = true;

  List<Node> parse() {
    _tokens = _scanner.scan();
    _currentDelimiters = _delimiters;
    _stack.clear();
    _stack.add(SectionNode('root', 0, 0, _delimiters));

    // Handle a standalone tag on first line, including special case where the
    // first line is empty.
    final Token? lineEnd = _readIf(TokenType.lineEnd, eofOk: true);
    if (lineEnd != null) {
      _appendTextToken(lineEnd);
    }
    _parseLine();

    for (Token? token = _peek(); token != null; token = _peek()) {
      switch (token.type) {
        case TokenType.text:
          _flushPendingWhitespace();
          _afterLineEnd = false;
          _read();
          _appendTextToken(token);

        case TokenType.whitespace:
          _read();
          if (_afterLineEnd) {
            _pendingWhitespace = (_pendingWhitespace ?? '') + token.value;
          } else {
            _flushPendingWhitespace();
            _appendTextToken(token);
          }

        case TokenType.openDelimiter:
          final Tag? tag = _readTag();
          final bool atLineStart = _afterLineEnd;
          final String indent = (atLineStart && _pendingWhitespace != null)
              ? _pendingWhitespace!
              : '';
          _pendingWhitespace = null;
          _afterLineEnd = false;
          final Node? node = _createNodeFromTag(tag, partialIndent: indent);
          if (node is ContainerNode) {
            node.startClearRight = atLineStart;
          }
          if (tag != null) {
            final bool consumesIndent =
                (tag.type == TagType.openBlock ||
                    tag.type == TagType.openParent) &&
                atLineStart;
            if (!consumesIndent && indent.isNotEmpty) {
              _appendTextToken(Token(TokenType.whitespace, indent, 0, 0));
            }
            _appendTag(tag, node);
          }

        case TokenType.changeDelimiter:
          _read();
          _currentDelimiters = token.value;

        case TokenType.lineEnd:
          _checkContainerTagClearRight();
          _flushPendingWhitespace();
          _afterLineEnd = true;
          _appendTextToken(_read()!);
          _parseLine();

        default:
          throw StateError('Unreachable code.');
      }
    }

    if (_stack.length != 1) {
      throw TemplateException(
        "Unclosed tag: '${_stack.last.name}'.",
        _templateName,
        _source,
        _stack.last.start,
      );
    }

    return _stack.last.children;
  }

  /// Check if the most recent non-whitespace token is an opensContainer tag or a close tag that
  /// corresponds to the node at the top of the stack, and mark it as clear right if so.
  void _checkContainerTagClearRight() {
    // Look back from the current offset for a non-whitespace token.
    Token? lastToken;
    int? lastOffset;
    for (int i = _offset - 1; i >= 0; i--) {
      lastToken = _tokens[i];
      if(lastToken.type != TokenType.whitespace) {
        lastOffset = i;
        break;
      }
    }

    // If there is no last token or it isn't a close delimiter, then
    // there is no container node to check.
    if (lastToken == null) {
      return;
    }

    if (lastToken.type != TokenType.closeDelimiter) {
      return;
    }

    // One token before the close delimiter is the name of the tag
    // (or a variable name, in the case of a variable tag).
    final int nameTokenOffset = lastOffset! - 1;
    final Token nameToken = _tokens[nameTokenOffset];
    if(nameToken.type != TokenType.identifier) {
      return;
    }

    // One token before the name token is the sigil, which
    // identifies the tag type.
    final int sigilTokenOffset = nameTokenOffset - 1;
    final Token sigilToken = _tokens[sigilTokenOffset];
    if (sigilToken.type != TokenType.sigil) {
      return;
    }

    final String sigil = sigilToken.value;
    final TagType? tagType = _tagTypeMap[sigil];
    if (tagType == null) {
      return;
    }

    // If the tag opens a container, then the container is on top of the
    // stack and start clear right.
    if (tagType.opensContainer) {
      final Node topOfStack = _stack.last;
      if(topOfStack is ContainerNode) {
        topOfStack.startClearRight = true;
      }
    }
    else {
      // If the tag closes a container, then the container is the
      // last container child of the top of the stack.
      final Node topOfStack = _stack.last;
      if(topOfStack is ContainerNode) {
        final List<Node> children = topOfStack.children;
        for(int i = children.length - 1; i >= 0; i--) {
          final Node child = children[i];
          if(child is ContainerNode) {
            child.endClearRight = true;
            break;
          }
        }
      }
    }
  }

  // Returns null on EOF.
  Token? _peek() => _offset < _tokens.length ? _tokens[_offset] : null;

  // Returns null on EOF.
  Token? _read() {
    Token? t;
    if (_offset < _tokens.length) {
      t = _tokens[_offset];
      _offset++;
    }
    return t;
  }

  Token _expect(TokenType type) {
    final Token? token = _read();
    if (token == null) {
      throw _errorEof();
    }
    if (token.type != type) {
      throw _error('Expected: $type found: ${token.type}.', _offset);
    }
    return token;
  }

  Token? _readIf(TokenType type, {bool eofOk = false}) {
    final Token? token = _peek();
    if (!eofOk && token == null) {
      throw _errorEof();
    }
    return token != null && token.type == type ? _read() : null;
  }

  TemplateException _errorEof() =>
      _error('Unexpected end of input.', _source.length - 1);

  TemplateException _error(String msg, int offset) =>
      TemplateException(msg, _templateName, _source, offset);

  void _flushPendingWhitespace() {
    if (_pendingWhitespace != null && _pendingWhitespace!.isNotEmpty) {
      _appendTextToken(Token(TokenType.whitespace, _pendingWhitespace!, 0, 0));
      _pendingWhitespace = null;
    }
  }

  // Add a text node to top most section on the stack and merge consecutive
  // text nodes together.
  void _appendTextToken(Token token) {
    assert(
      const <TokenType>[
        TokenType.text,
        TokenType.lineEnd,
        TokenType.whitespace,
      ].contains(token.type),
    );
    final List<Node> children = _stack.last.children;
    if (children.isEmpty || children.last is! TextNode) {
      children.add(TextNode(token.value, token.start, token.end));
    } else {
      final last = children.removeLast() as TextNode;
      final node = TextNode(last.text + token.value, last.start, token.end);
      children.add(node);
    }
  }

  // Add the node to top most section on the stack. If a section/parent/block
  // node then push it onto the stack, if a close section tag, then pop.
  void _appendTag(Tag tag, Node? node) {
    switch (tag.type) {
      // {{#...}}  {{^...}}  {{<...}}  {{$...}}
      case TagType.openSection:
      case TagType.openInverseSection:
      case TagType.openParent:
      case TagType.openBlock:
        _stack.last.children.add(node!);
        _stack.add(node as ContainerNode);

      // {{/...}}
      case TagType.closeSection:
        if (tag.name != _stack.last.name) {
          throw TemplateException(
            'Mismatched tag, expected: '
            "'${_stack.last.name}', was: '${tag.name}'",
            _templateName,
            _source,
            tag.start,
          );
        }
        final ContainerNode popped = _stack.removeLast();
        if (popped is SectionNode) {
          popped.contentEnd = tag.start;
        }

      // {{...}} {{&...}} {{{...}}}
      case TagType.variable:
      case TagType.unescapedVariable:
      case TagType.tripleMustache:
      case TagType.partial:
        if (node != null) {
          _stack.last.children.add(node);
        }

      case TagType.comment:
      case TagType.changeDelimiter:
        // Ignore.
        break;

      default:
        throw StateError('Unreachable code.');
    }
  }

  // Handle standalone tags and indented partials.
  //
  // A "standalone tag" in the spec is one or more tags on a line where the line only
  // contains whitespace. During rendering the whitespace is omitted.
  // Standalone partials also indent their content to match the tag during
  // rendering.

  // match:
  // lineEnd whitespace openDelimiter any* closeDelimiter whitespace lineEnd
  //
  // Where lineEnd can also mean start/end of the source.
  void _parseLine() {
    // If first token is a newline append it.
    final Token? t = _peek();
    if (t != null && t.type == TokenType.lineEnd) {
      _appendTextToken(t);
    }

    // Continue parsing standalone lines until we find one that isn't a
    // standalone line.
    while (_peek() != null) {
      _readIf(TokenType.lineEnd, eofOk: true);

      final Token? precedingWhitespace = _readIf(
        TokenType.whitespace,
        eofOk: true,
      );
      final String indent = precedingWhitespace == null
          ? ''
          : precedingWhitespace.value;

      final List<Tag> tags = [];
      final Map<Tag, Node> tagNodes = {};

      Tag? tag = _readTag();
      while(tag != null) {
        tags.add(tag);
        final Node? node = _createNodeFromTag(tag, partialIndent: indent);

        if(node != null) {
          tagNodes[tag] = node;
        }
        tag = _readTag();
      }
      final Token? followingWhitespace = _readIf(
        TokenType.whitespace,
        eofOk: true,
      );

      const standaloneTypes = <TagType>[
        TagType.openSection,
        TagType.closeSection,
        TagType.openInverseSection,
        TagType.partial,
        TagType.openParent,
        TagType.openBlock,
        TagType.comment,
        TagType.changeDelimiter,
      ];

      final bool isStandaloneLine =
        tags.isNotEmpty &&
        tags.every((Tag tag) => standaloneTypes.contains(tag.type)) &&
        (_peek() == null || _peek()!.type == TokenType.lineEnd);

      if (isStandaloneLine) {
        // This is a tag on a "standalone line", so do not create text nodes
        // for whitespace, or the following newline.
        for(final tag in tags) {
          // Record standalone status of the tag.
          final Node? tagNode;
          if(tag.type.opensContainer) {
            tagNode = tagNodes[tag];
          }
          else {
            tagNode = _getContainerNodeForCloseTag(tag);
          }

          if(tagNode is ContainerNode) {
            // This is a standalone tag, so it is clear on both sides.
            if(tag.type.opensContainer) {
              tagNode.startClearLeft = true;
              tagNode.startClearRight = true;
            }
            else {
              tagNode.endClearLeft = true;
              tagNode.endClearRight = true;
            }
          }

          _appendTag(tag, tagNodes[tag]);
        }

        // Standalone block tags are a special case.
        // {{$block}}{{/block}} is standalone by the strict definition, but the actual behavior
        // is more like {{#block}}...{{/block}}, i.e., a section with content. {{#block}}...{{/block}}
        // should retain its trailing newline, so {{$block}}{{/block}} (or the same with standalone-eligible
        // tags inside) should also retain its trailing newline.
        if (tags.length >= 2) {
          final Tag firstTag = tags.first;
          final Tag lastTag = tags.last;
          if(firstTag.type == TagType.openBlock && lastTag.type == TagType.closeSection && firstTag.name == lastTag.name) {
            final Token? lineEnd = _readIf(TokenType.lineEnd, eofOk: true);
            if(lineEnd != null) {
              _appendTextToken(lineEnd);
            }
          }
        }
        // Now continue to loop and parse the next line.
      } else {
        // This is not a standalone line so add the whitespace to the AST.
        if (precedingWhitespace != null) {
          // openBlock is a special case: even though it occurs inline here rather than standalone,
          // we don't want to include the preceding whitespace separately in the AST, because openBlock's
          // indent already sets the preceding whitespace.
          final bool includePrecedingWhitespace = tags.isEmpty || tags.last.type != TagType.openBlock;
          if (includePrecedingWhitespace) {
            _appendTextToken(precedingWhitespace);
          }
        }
        for(final tag in tags) {
          // Record standalone status of the tag.
          final Node? tagNode;
          if(tag.type.opensContainer) {
            tagNode = tagNodes[tag];
          }
          else {
            tagNode = _getContainerNodeForCloseTag(tag);
          }

          if(tagNode is ContainerNode) {
            // We're parsing the beginning of a line, so the tag is
            // clear left.
            if(tag.type.opensContainer) {
              tagNode.startClearLeft = true;
            }
            else {
              tagNode.endClearLeft = true;
            }
          }

          _appendTag(tag, tagNodes[tag]);
        }
        if (followingWhitespace != null) {
          _appendTextToken(followingWhitespace);
        }
        // Done parsing standalone lines. Exit the loop.
        break;
      }
    }
  }

  /// Returns the container node for [tag], if [tag] is a close tag and
  /// its name matches the name of the container node at the top of the stack.
  ContainerNode? _getContainerNodeForCloseTag(Tag tag) {
    if(tag.type != TagType.closeSection) {
      return null;
    }
    final Node? topOfStack = _stack.last;
    if(topOfStack is ContainerNode) {
      if(topOfStack.name == tag.name) {
        return topOfStack;
      }
    }
    return null;
  }

  final RegExp _validIdentifier = RegExp(r'^[0-9a-zA-Z\_\-\.]+$');

  static const Map<String, TagType> _tagTypeMap = <String, TagType>{
    '#': TagType.openSection,
    '^': TagType.openInverseSection,
    '/': TagType.closeSection,
    '&': TagType.unescapedVariable,
    '>': TagType.partial,
    '!': TagType.comment,
    '<': TagType.openParent,
    r'$': TagType.openBlock,
  };

  // If open delimiter, or change delimiter token then return a tag.
  // If EOF or any another token then return null.
  Tag? _readTag() {
    final Token? t = _peek();
    if (t == null ||
        (t.type != TokenType.changeDelimiter &&
            t.type != TokenType.openDelimiter)) {
      return null;
    } else if (t.type == TokenType.changeDelimiter) {
      _read();
      // Remember the current delimiters.
      _currentDelimiters = t.value;

      // Change delimiter tags are already parsed by the scanner.
      // So just create a tag and return it.
      return Tag(TagType.changeDelimiter, t.value, t.start, t.end);
    }

    // Start parsing a typical tag.

    final Token open = _expect(TokenType.openDelimiter);

    _readIf(TokenType.whitespace);

    // A sigil is the character which identifies which sort of tag it is,
    // i.e.  '#', '/', or '>'.
    // Variable tags and triple mustache tags don't have a sigil.
    TagType? tagType;

    if (open.value == '{{{') {
      tagType = TagType.tripleMustache;
    } else {
      final Token? sigil = _readIf(TokenType.sigil);
      tagType = sigil == null ? TagType.variable : _tagTypeMap[sigil.value];
    }

    _readIf(TokenType.whitespace);

    // TODOsplit up names here instead of during render.
    // Also check that they are valid token types.
    // TODOsplit up names here instead of during render.
    // Also check that they are valid token types.
    final list = <Token>[];
    for (
      Token? t = _peek();
      t != null && t.type != TokenType.closeDelimiter;
      t = _peek()
    ) {
      _read();
      list.add(t);
    }
    final String name = list.map((Token t) => t.value).join().trim();
    if (_peek() == null) {
      throw _errorEof();
    }

    // Check to see if the tag name is valid.
    if (tagType != TagType.comment) {
      if (name == '') {
        throw _error('Empty tag name.', open.start);
      }
      if (!_lenient) {
        if (name.contains('\t') || name.contains('\n') || name.contains('\r')) {
          throw _error('Tags may not contain newlines or tabs.', open.start);
        }

        if (!_validIdentifier.hasMatch(name)) {
          throw _error(
            'Unless in lenient mode, tags may only contain the '
            'characters a-z, A-Z, minus, underscore and period.',
            open.start,
          );
        }
      }
    }

    final Token close = _expect(TokenType.closeDelimiter);

    return Tag(tagType!, name, open.start, close.end);
  }

  Node? _createNodeFromTag(Tag? tag, {String partialIndent = ''}) {
    // Handle EOF case.
    if (tag == null) {
      return null;
    }

    Node? node;
    switch (tag.type) {
      case TagType.openSection:
      case TagType.openInverseSection:
        final inverse = tag.type == TagType.openInverseSection;
        node = SectionNode(
          tag.name,
          tag.start,
          tag.end,
          _currentDelimiters,
          inverse: inverse,
        );

      case TagType.variable:
      case TagType.unescapedVariable:
      case TagType.tripleMustache:
        final escape = tag.type == TagType.variable;
        node = VariableNode(tag.name, tag.start, tag.end, escape: escape);

      case TagType.partial:
        node = PartialNode(tag.name, tag.start, tag.end, partialIndent);

      case TagType.openParent:
        node = ParentNode(tag.name, tag.start, tag.end, partialIndent);

      case TagType.openBlock:
        node = BlockNode(tag.name, tag.start, tag.end, indent: partialIndent);

      case TagType.closeSection:
      case TagType.comment:
      case TagType.changeDelimiter:
        node = null;

      default:
        throw StateError('Unreachable code.');
    }
    return node;
  }
}
