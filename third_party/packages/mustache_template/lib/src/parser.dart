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

  static final RegExp _lineEndRegex = RegExp(r'\r?\n');
  static final RegExp _nonNewlineWhitespaceRegex = RegExp(r'[\r\t ]+');
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
    _stack.add(SectionNode('root', 0, 0, null, _delimiters));

    // Handle a standalone tag on first line, including special case where the
    // first line is empty.
    final Token? lineEnd = _readIf(TokenType.lineEnd, eofOk: true);
    if (lineEnd != null) {
      _appendTextToken(lineEnd);
    }
    final bool lineStartsWithTag = _parseLine();
    if (lineStartsWithTag) {
      // There will be no pending whitespace at this point, because
      // _parseLine handles all tokens up to the close delimiter of
      // the first tag.
      _afterLineEnd = false;
    }

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
            node.startClearLeft = atLineStart;
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

    // If the template doesn't end with a newline, check:
    // 1. if the last token is a close delimeter
    // 2. if that close delimiter closes a container tag
    // 3. if that closing tag clears right
    _checkContainerTagClearRight();

    if (_stack.length != 1) {
      throw TemplateException(
        "Unclosed tag: '${_stack.last.name}'.",
        _templateName,
        _source,
        _stack.last.start,
      );
    }

    _standalonePass(_stack.last);

    return _stack.last.children;
  }

  /// The first pass over the AST handles only those tags that are standalone by the strict, original definition:
  /// A single tag on a line with no whitespace. This second pass handles the more complex cases introduced
  /// by the inheritance specification, where complete _nodes_ (i.e., {{<parent}}{{!content}}{{/parent}}) can
  /// behave as standalone as well as just their tags.
  ///
  /// Definitions used in this comment:
  ///
  /// -'clear' or 'clears' below means 'has nothing but whitespace until a line boundary on the given side',
  /// with the noun and verb forms used interchangeably:
  ///   - `  {{<test}}xx\n` clears left.
  ///   - `xx{{/test}}  \n` is clear right.
  ///   - A tag pair clears if its opening tag has left clearance and its closing tag has right clearance.
  ///   - A tag pair has inner clearance if its opening tag clears right and its closing tag clears left.
  /// - 'whitespace' refers to specifically non-line-ending whitespace that occurs between a line break and
  ///   the open delimiter of a tag, or between the close delimiter of a tag and a line break.
  ///
  /// When a node behaves as standalone, we look forward and back among its siblings to see if there is
  /// surrounding whitespace (i.e., if the preceding text node ends with whitespace or the next text node
  /// begins with whitespace). If so, we remove any whitespace from the preceding text node up until a
  /// newline (which we leave in the preceding node), and remove any whitespace from the next text node up
  /// to and including a newline.
  ///
  /// 1. A pair of parent tags and their entire content should be treated as standalone if the parent
  /// tag pair clears.
  ///
  /// 2. An argument block (i.e., `{{$block}}...{{/block}}` within a pair of `{{<parent}}` tags)
  /// is standalone if it has inner clearance. Note that the block tags may not
  /// be strictly standalone: e.g. `{{<parent}}{{$block}}\n{{!content}}\n{{/block}}{{/parent}}`).
  /// Neither block tag is standalone, but the pair has inner clearance, so we remove trailing whitespace
  /// from after each tag, and remove a trailing newline from after the opening tag. Note that the trailing
  /// newline occurs _inside_ the block, so we must look at the first text node within the block's content.\
  /// \
  /// Additionally, and unrelatedly, if an argument block's opening tag has inner clearance, the indentation
  /// of the first line of the block's content becomes the block node's intrinsic indentation.
  ///
  /// 3. For a parameter block (i.e. `{{$block}}...{{/block}}` in a template without surrounding parent tags),
  /// trailing whitespace and newlines are removed based on whether the closing tag is strictly standalone.
  ///
  /// 4. Both argument and parameter blocks always consume leading whitespace. This is a no-op in most cases,
  /// but handles the case where the block tag is not standalone and is indented, with only whitespace ahead
  /// of it: `    {{$block}}content{{/block}}`. That preceding whitespace is stored in the block node's
  /// `indent` field during the first parsing pass, and will be applied to all rendered content during the
  /// render step, so it must be removed from the preceding text node here.
  ///
  /// Whenever a block node has a nonempty value in its `indent` field, that block has **intrinsic
  /// indentation**. Intrinsic indentation comes either from the indent before the open block tag for
  /// non-standalone but non-inline blocks, or from the indentation of the first line of the block's content,
  /// when either the block is an argument and its start tag clears right, or the block is a parameter,
  /// the block tag pair is standalone, and the opening tag is standalone.
  ///
  /// When a block has intrinsic indentation, that indentation is removed from all its lines, such that
  /// the first line of the block is unindented in the text nodes contained within. At render time, the
  /// intrinsic indentation of the block in the outermost parent template is added to the start of each
  /// line in the resolved block content.
  ///
  /// These rules come from a discussion in the mustache spec repository:
  /// https://github.com/mustache/spec/discussions/203
  ///
  /// The behavior of this implementation should mirror the behavior of [Wontache](https://gitlab.com/jgonggrijp/wontache),
  /// whose author is a mustache maintainer and the author of the inheritance optional spec.
  void _standalonePass(ContainerNode container) {
    for(var i = 0; i < container.children.length; i++) {
      final Node child = container.children[i];
      if (child is ContainerNode) {
        TextNode? precedingText;
        TextNode? followingText;
        if (i > 0) {
          final Node precedingNode = container.children[i - 1];
          if (precedingNode is TextNode) {
            precedingText = precedingNode;
          }
        }
        if (i < container.children.length - 1) {
          final Node followingNode = container.children[i + 1];
          if (followingNode is TextNode) {
            followingText = followingNode;
          }
        }

        _checkAndUpdateSurroundingWhitespace(child, precedingText, followingText);
        _checkAndUpdateIntrinsicIndentation(child);
        _standalonePass(child);
      }
    }
  }

  /// Check and update the surrounding whitespace of a parent or block node. These behave differently
  /// from sections in that the standalone rules are applied to
  void _checkAndUpdateSurroundingWhitespace(ContainerNode container, TextNode? precedingTextNode, TextNode? followingTextNode) {
    var shouldConsumeLeadingWhitespace = false;
    var shouldConsumeTrailingWhitespace = false;

    if (container is ParentNode) {
      shouldConsumeLeadingWhitespace = container.isContainerStandalone;
      shouldConsumeTrailingWhitespace = container.isContainerStandalone;
    } else if (container is BlockNode) {
      // Blocks behave slightly differently from partials/sections, the upshot of which is that
      // we always want to consume whitespace on the line before the block's opening tag.
      // Three cases:
      // 1. The opening tag is fully standalone. There is no line-initial whitespace to consume;
      //    it was already handled during the first pass.
      // 2. The opening tag is not standalone and is indented, with only whitespace ahead of it.
      //    We consume that whitespace, because it already became the block's indentation during
      //    the first parse pass, and we don't want to double it when rendering the block.
      // 3. The opening tag is not standalone and occurs inline with other running text. There is
      //    no leading whitespace to consume (textBeforeContainer.trim() is nonempty).
      shouldConsumeLeadingWhitespace = true;

      if (container.isArgument) {
        shouldConsumeTrailingWhitespace = container.endClearLeft;
      }
    }

    if (shouldConsumeLeadingWhitespace) {
      if(precedingTextNode != null) {
        // Consume all trailing whitespace following the final newline (i.e. before this tag)
        // from the prior text node.

        // \r\n safety: we always keep the \r by substringing past the index of \n.
        final int lastNewline = precedingTextNode.text.lastIndexOf('\n');
        if (lastNewline != -1) {
          final String textBeforeContainer = precedingTextNode.text.substring(lastNewline + 1);
          if (textBeforeContainer.trim().isEmpty) {
            precedingTextNode.text = precedingTextNode.text.substring(0, lastNewline + 1);
          }
        }
      }
    }

    if (shouldConsumeTrailingWhitespace) {
      if(followingTextNode != null) {
        // Consume all leading whitespace before the first newline (i.e. after this tag)
        // from the following text node, including that newline itself.

        // \r\n safety: we keep neither the \r nor the \n if we substring past \n.
        final int firstNewline = followingTextNode.text.indexOf('\n');
        if (firstNewline != -1) {
          final String textAfterContainer = followingTextNode.text.substring(0, firstNewline);
          if (textAfterContainer.trim().isEmpty) {
            if (firstNewline + 1 >= followingTextNode.text.length) {
              // If the text after the container is only a newline or is empty, then set the text node to empty.
              followingTextNode.text = '';
            } else {
              // Otherwise, consume the leading whitespace and newline.
              followingTextNode.text = followingTextNode.text.substring(firstNewline + 1);
            }
          }
        }
      }
    }
  }

  /// Detect the intrinsic indentation of a block node, which is the indentation of the first non-whitespace line
  /// in the block. If the block has intrinsic indentation, then set the block's indent to that indentation and
  /// remove that indentation from all of the block's lines. (Intrinsic indentation is added to the resolved
  /// content of a block during rendering.)
  void _checkAndUpdateIntrinsicIndentation(ContainerNode container) {
    if (container is! BlockNode) {
      return;
    }

    final BlockNode block = container;

    var intrinsicIndentationFromFirstLine = false;
    if (block.isArgument) {
      intrinsicIndentationFromFirstLine = block.startClearRight;
    } else {
      intrinsicIndentationFromFirstLine = block.isContainerStandalone && block.isStartStandalone;
    }

    if (intrinsicIndentationFromFirstLine) {
      // Find the first text node in the container.
      TextNode? firstText;
      Node? nodeAfterFirstText;
      for (final Node child in block.children) {
        if (firstText == null && child is TextNode) {
          firstText = child;
        } else if (firstText != null && nodeAfterFirstText == null) {
          nodeAfterFirstText = child;
          break;
        }
      }

      if (firstText != null) {
        // An argument block's start tag is standalone if it clears right, so if the template
        // content begins with nothing but whitespace up until a newline, remove it.

        // \r\n safety: we look for all non-\n whitespace characters including \r in our prefix, and
        // substringing on the index of \n discards the \r.
        if (block.isArgument && block.startClearRight && firstText.text.startsWith(RegExp(r'^[\r\t ]*\n'))) {
          final int newlineIndex = firstText.text.indexOf('\n');
          if (newlineIndex != -1) {
            firstText.text = firstText.text.substring(newlineIndex + 1);
          }
        }

        // Find the first line that isn't just a newline in the first text node.
        final List<String> lines = firstText.text.split(RegExp(r'\r?\n'));
        for(final line in lines) {
          if (line.isNotEmpty) {
            // The leading indentation of that line is the intrinsic indentation.
            final int firstNonWhitespaceIndex = line.indexOf(RegExp(r'[\S]'));
            if (firstNonWhitespaceIndex != -1) {
              block.indent = line.substring(0, firstNonWhitespaceIndex);
            } else if (nodeAfterFirstText != null) {
              // There is a non-text node on this line after the contents of the
              // first text node, so the intrinsic indentation is the entire 'line'
              // string (i.e., the whitespace before the non-text node).
              block.indent = line;
            }
            break;
          }
        }

        // If this container is standalone, remove the leading newline from the first text node.
        if ((block.isContainerStandalone || block.isInnerStandalone) && firstText.text.startsWith(_lineEndRegex)) {
          firstText.text = firstText.text.replaceFirst(_lineEndRegex, '');
        }
      }
    }

    // For nested blocks, intrinsic indentation is relative to the parent block's indendation,
    // so subtract the indentation of any ancestor blocks from this block's intrinsic indentation.
    final String originalIntrinsicIndentation = block.indent;
    String intrinsicIndentation = block.indent;
    Node? parent = block.parent;
    while (parent != null) {
      if (parent is BlockNode) {
        // Remove parent indentation from the end of the intrinsic indentation, to hopefully
        // catch mixed tab/space scenarios.
        intrinsicIndentation = intrinsicIndentation.substring(0, intrinsicIndentation.length - parent.indent.length);
      }
      parent = parent.parent;
    }
    block.indent = intrinsicIndentation;

    // If the container has intrinsic indentation, then remove that indentation
    // from all of the container's lines.

    // \r\n safety: splitting on \n preserves the \r at the end of each line, so
    // joining by \n restores any CRLF endings.
    if (block.indent.isNotEmpty) {
      for(final Node child in block.children) {
        if (child is TextNode) {
          final List<String> lines = child.text.split('\n');
          for(var i = 0; i < lines.length; i++) {
            String line = lines[i];
            if (line.startsWith(originalIntrinsicIndentation)) {
              line = line.substring(originalIntrinsicIndentation.length);
            }
            lines[i] = line;
          }
          child.text = lines.join('\n');
        }
      }
    }

    // If the block's content has whitespace after a trailing newline, remove it.
    TextNode? lastText;
    for(final Node child in block.children) {
      if (child is TextNode) {
        lastText = child;
      }
    }
    if (lastText != null) {
      final int lastNewline = lastText.text.lastIndexOf('\n');
      if (lastNewline != -1) {
        final String textAfterLastNewline = lastText.text.substring(lastNewline + 1);
        if (textAfterLastNewline.trim().isEmpty) {
          lastText.text = lastText.text.substring(0, lastNewline + 1);
        }
      }
    }
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
    final Node parent = _stack.last;
    final List<Node> children = _stack.last.children;
    if (children.isEmpty || children.last is! TextNode) {
      children.add(TextNode(token.value, token.start, token.end, parent));
    } else {
      final last = children.removeLast() as TextNode;
      final node = TextNode(last.text + token.value, last.start, token.end, parent);
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
  //
  // Returns true if any tags were parsed.
  bool _parseLine() {
    // If first token is a newline append it.
    final Token? t = _peek();
    if (t != null && t.type == TokenType.lineEnd) {
      _appendTextToken(t);
    }

    var parsedTag = false;

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

      final Tag? tag = _readTag();
      if(tag != null) {
        parsedTag = true;
        tags.add(tag);
        final Node? node = _createNodeFromTag(tag, partialIndent: indent);
        if(node != null) {
          tagNodes[tag] = node;
        }
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
        tag != null &&
        standaloneTypes.contains(tag.type) &&
        (_peek() == null || _peek()!.type == TokenType.lineEnd);

      if (isStandaloneLine) {
        // This is a tag on a "standalone line", so do not create text nodes
        // for whitespace, or the following newline.
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

        // Now continue to loop and parse the next line.
      } else {
        // This is not a standalone line so add the whitespace to the AST.
        if (precedingWhitespace != null) {
          _appendTextToken(precedingWhitespace);
        }

        // Record standalone status of the tag.
        Node? tagNode;
        if(tag != null) {
          parsedTag = true;
          if(tag.type.opensContainer) {
            tagNode = tagNodes[tag];
          }
          else {
            tagNode = _getContainerNodeForCloseTag(tag);
          }
        }

        if(tag != null && tagNode != null && tagNode is ContainerNode) {
          // We're parsing the beginning of a line, so the tag is
          // clear left.
          if(tag.type.opensContainer) {
            tagNode.startClearLeft = true;
          }
          else {
            tagNode.endClearLeft = true;
          }
        }

        if(tag != null) {
          _appendTag(tag, tagNodes[tag]);
        }

        if (followingWhitespace != null) {
          _appendTextToken(followingWhitespace);
        }
        // Done parsing standalone lines. Exit the loop.
        break;
      }
    }

    return parsedTag;
  }

  /// Returns the container node for [tag], if [tag] is a close tag and
  /// its name matches the name of the container node at the top of the stack.
  ContainerNode? _getContainerNodeForCloseTag(Tag tag) {
    if(tag.type != TagType.closeSection) {
      return null;
    }
    final Node topOfStack = _stack.last;
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
          _stack.last,
          _currentDelimiters,
          inverse: inverse,
        );

      case TagType.variable:
      case TagType.unescapedVariable:
      case TagType.tripleMustache:
        final escape = tag.type == TagType.variable;
        node = VariableNode(tag.name, tag.start, tag.end, _stack.last, escape: escape);

      case TagType.partial:
        node = PartialNode(tag.name, tag.start, tag.end, partialIndent, _stack.last);

      case TagType.openParent:
        node = ParentNode(tag.name, tag.start, tag.end, partialIndent, _stack.last);

      case TagType.openBlock:
        node = BlockNode(tag.name, tag.start, tag.end, _stack.last, indent: partialIndent);

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
