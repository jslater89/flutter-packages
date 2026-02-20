// TODO(stuartmorgan): Remove this. See https://github.com/flutter/flutter/issues/174722.
// ignore_for_file: public_member_api_docs

import '../mustache.dart' as m;
import 'lambda_context.dart';
import 'node.dart';
import 'template.dart';
import 'template_exception.dart';

const Object noSuchProperty = Object();
final RegExp _integerTag = RegExp(r'^[0-9]+$');

class Renderer extends Visitor {
  Renderer(
    this.sink,
    List<Object?> stack,
    this.lenient,
    this.htmlEscapeValues,
    this.partialResolver,
    this.templateName,
    this.indent,
    this.source, {
    Map<String, List<Node>> blockOverrides = const {},
    Map<String, String> blockIndentOverrides = const {},
  }) : _stack = List<Object?>.from(stack),
       _blockOverrides = blockOverrides,
       _blockIndentOverrides = blockIndentOverrides;

  Renderer.partial(Renderer ctx, Template partial, String indent)
    : this(
        ctx.sink,
        ctx._stack,
        ctx.lenient,
        ctx.htmlEscapeValues,
        ctx.partialResolver,
        ctx.templateName,
        ctx.indent + indent,
        partial.source,
      );

  Renderer.parent(
    Renderer ctx,
    Template parent,
    String indent,
    Map<String, List<Node>> blockOverrides, {
    Map<String, String> blockIndentOverrides = const {},
  }) : this(
         ctx.sink,
         ctx._stack,
         ctx.lenient,
         ctx.htmlEscapeValues,
         ctx.partialResolver,
         ctx.templateName,
         ctx.indent + indent,
         parent.source,
         blockOverrides: blockOverrides,
         blockIndentOverrides: blockIndentOverrides.isNotEmpty
             ? blockIndentOverrides
             : ctx._blockIndentOverrides,
       );

  Renderer.subtree(Renderer ctx, StringSink sink)
    : this(
        sink,
        ctx._stack,
        ctx.lenient,
        ctx.htmlEscapeValues,
        ctx.partialResolver,
        ctx.templateName,
        ctx.indent,
        ctx.source,
      );

  Renderer.lambda(Renderer ctx, String source, String indent, StringSink sink)
    : this(
        sink,
        ctx._stack,
        ctx.lenient,
        ctx.htmlEscapeValues,
        ctx.partialResolver,
        ctx.templateName,
        ctx.indent + indent,
        source,
      );

  final StringSink sink;
  final List<Object?> _stack;
  final bool lenient;
  final bool htmlEscapeValues;
  final m.PartialResolver? partialResolver;
  final String? templateName;
  final String indent;
  final String source;
  final Map<String, List<Node>> _blockOverrides;
  final Map<String, String> _blockIndentOverrides;

  void push(Object? value) => _stack.add(value);

  Object? pop() => _stack.removeLast();

  void write(Object output) => sink.write(output.toString());

  void render(List<Node> nodes) {
    if (indent == '') {
      for (final n in nodes) {
        n.accept(this);
      }
    } else if (nodes.isNotEmpty) {
      // Special case to make sure there is not an extra indent after the last
      // line in the partial file.
      write(indent);

      nodes.take(nodes.length - 1).forEach((Node n) => n.accept(this));

      final Node node = nodes.last;
      if (node is TextNode) {
        visitText(node, lastNode: true);
      } else {
        node.accept(this);
      }
    }
  }

  @override
  void visitText(TextNode node, {bool lastNode = false}) {
    if (node.text == '') {
      return;
    }
    if (indent == '') {
      write(node.text);
    } else if (lastNode && node.text.runes.last == _NEWLINE) {
      // Don't indent after the last line in a template.
      final String s = node.text.substring(0, node.text.length - 1);
      write(s.replaceAll('\n', '\n$indent'));
      write('\n');
    } else {
      write(node.text.replaceAll('\n', '\n$indent'));
    }
  }

  @override
  void visitVariable(VariableNode node) {
    Object? value = resolveValue(node.name);

    if (value is Function) {
      final context = LambdaContext(node, this);
      final Function valueFunction = value;
      // TODO(stuartmorgan): Add function typing in a way that doesn't break
      //  backward compatibility.
      // ignore: avoid_dynamic_calls
      value = valueFunction(context);
      context.close();
    }

    if (value == noSuchProperty) {
      if (!lenient) {
        throw error('Value was missing for variable tag: ${node.name}.', node);
      }
    } else {
      final valueString = (value == null) ? '' : value.toString();
      final String output = !node.escape || !htmlEscapeValues
          ? valueString
          : _htmlEscape(valueString);
      write(output);
    }
  }

  @override
  void visitSection(SectionNode node) {
    if (node.inverse) {
      _renderInvSection(node);
    } else {
      _renderSection(node);
    }
  }

  void _renderSection(SectionNode node) {
    final Object? value = resolveValue(node.name);

    if (value == null) {
      // Do nothing.
    } else if (value is Iterable) {
      for (final Object? v in value) {
        _renderWithValue(node, v);
      }
    } else if (value is Map) {
      _renderWithValue(node, value);
    } else if (value == true) {
      _renderWithValue(node, value);
    } else if (value == false) {
      // Do nothing.
    } else if (value == noSuchProperty) {
      if (!lenient) {
        throw error('Value was missing for section tag: ${node.name}.', node);
      }
    } else if (value is Function) {
      final context = LambdaContext(node, this);
      // TODO(stuartmorgan): Add function typing in a way that doesn't break
      //  backward compatibility.
      // ignore: avoid_dynamic_calls
      final Object? output = value(context);
      context.close();
      if (output != null) {
        write(output);
      }
    } else {
      // Assume the value might have accessible member values via mirrors.
      _renderWithValue(node, value);
    }
  }

  void _renderInvSection(SectionNode node) {
    final Object? value = resolveValue(node.name);

    if (value == null) {
      _renderWithValue(node, null);
    } else if ((value is Iterable && value.isEmpty) || value == false) {
      _renderWithValue(node, node.name);
    } else if (value == true || value is Map || value is Iterable) {
      // Do nothing.
    } else if (value == noSuchProperty) {
      if (lenient) {
        _renderWithValue(node, null);
      } else {
        throw error(
          'Value was missing for inverse section: ${node.name}.',
          node,
        );
      }
    } else if (value is Function) {
      // Do nothing.
      // TODO(stuartmorgan): Determine whether this should be an error in
      //  strict mode (per comment in initial source import).
    } else if (lenient) {
      // We consider all other values as 'true' in lenient mode. Since this
      // is an inverted section, we do nothing.
    } else {
      throw error(
        'Invalid value type for inverse section, '
        'section: ${node.name}, '
        'type: ${value.runtimeType}.',
        node,
      );
    }
  }

  void _renderWithValue(SectionNode node, Object? value) {
    push(value);
    node.visitChildren(this);
    pop();
  }

  @override
  void visitPartial(PartialNode node) {
    final String partialName = node.name;
    final Template? template = partialResolver == null
        ? null
        : (partialResolver!(partialName) as Template?);
    if (template != null) {
      final renderer = Renderer.partial(this, template, node.indent);
      final List<Node> nodes = getTemplateNodes(template);
      renderer.render(nodes);
    } else if (lenient) {
      // do nothing
    } else {
      throw error('Partial not found: $partialName.', node);
    }
  }

  @override
  void visitParent(ParentNode node) {
    // Collect block overrides from this parent's children (only BlockNodes).
    final overridesFromChild = <String, List<Node>>{};

    for (var i = 0; i < node.children.length; i++) {
      final Node child = node.children[i];
      if (child is BlockNode) {
        overridesFromChild[child.name] = child.children;
      }
    }
    // Merge with current overrides: existing (outer/descendant) overrides take precedence.
    final merged = Map<String, List<Node>>.from(
      _blockOverrides,
    );
    for (final MapEntry<String, List<Node>> e in overridesFromChild.entries) {
      merged.putIfAbsent(e.key, () => e.value);
    }
    final String parentName = node.name;
    final Template? template = partialResolver == null
        ? null
        : (partialResolver!(parentName) as Template?);
    if (template != null) {
      final List<Node> nodes = getTemplateNodes(template);
      final Map<String, String> templateBlockIndents = _collectBlockIndents(
        nodes,
      );
      final parentIndents = Map<String, String>.from(
        _blockIndentOverrides,
      );
      // Merge with current indents: new (inner/ancestor) overrides take precedence.
      for (final MapEntry<String, String> e in templateBlockIndents.entries) {
        parentIndents[e.key] = e.value;
      }
      final renderer = Renderer.parent(
        this,
        template,
        node.indent,
        merged,
        blockIndentOverrides: parentIndents,
      );
      renderer.render(nodes);
    } else if (lenient) {
      // do nothing
    } else {
      throw error('Parent not found: $parentName.', node);
    }
  }

  @override
  void visitBlock(BlockNode node) {
    final List<Node>? override = _blockOverrides[node.name];
    if (override != null && override.isNotEmpty) {
      _renderBlockOverride(node, override);
    } else {
      node.visitChildren(this);
    }
  }

  /// Expansion indent for a block (from this template or from indent overrides).
  String _expansionIndentFor(BlockNode block) {
    return _blockIndentOverrides[block.name] ??
        (block.indent.isNotEmpty
            ? block.indent
            : _computeIndentFromContent(block.children));
  }

  /// Collects block name -> expansion indent for all BlockNodes in [nodes].
  Map<String, String> _collectBlockIndents(List<Node> nodes) {
    final out = <String, String>{};
    void visit(Node n) {
      if (n is BlockNode) {
        out[n.name] = n.indent.isNotEmpty
            ? n.indent
            : _computeIndentFromContent(n.children);
      }
      if (n is ContainerNode) {
        n.children.forEach(visit);
      }
    }
    nodes.forEach(visit);
    return out;
  }

  /// Renders block override content with reindentation: strip common leading
  /// whitespace from the override, then apply the block's expansion indent.
  ///
  /// When the override contains nested blocks, each level is stripped and
  /// reindented independently so that inner blocks keep the indentation their
  /// own [_renderBlockOverride] applied.
  void _renderBlockOverride(BlockNode block, List<Node> overrideNodes) {
    final String expansionIndent = _expansionIndentFor(block);
    final childIndents = Map<String, String>.from(
      _blockIndentOverrides,
    );
    childIndents[block.name] = expansionIndent;

    final bool hasNestedBlocks =
        overrideNodes.any((Node n) => n is BlockNode || n is ParentNode);

    if (!hasNestedBlocks) {
      String raw = _renderNodesToString(overrideNodes, childIndents);
      if (raw.startsWith('\n')) {
        raw = raw.substring(1);
      }
      final String stripped = _stripCommonIndent(raw);
      _writeReindented(stripped, expansionIndent);
      return;
    }

    // Compute common indent from text nodes at this level only, so that
    // already-reindented output from nested blocks is not disturbed.
    String textOnly = _staticRenderNodesToText(overrideNodes);
    if (textOnly.startsWith('\n')) {
      textOnly = textOnly.substring(1);
    }
    final String commonIndent = _getCommonIndent(textOnly);

    final sub = Renderer(
      sink,
      _stack,
      lenient,
      htmlEscapeValues,
      partialResolver,
      templateName,
      '',
      source,
      blockOverrides: _blockOverrides,
      blockIndentOverrides: childIndents,
    );

    var isFirst = true;
    for (final node in overrideNodes) {
      if (node is TextNode) {
        String text = node.text;
        if (isFirst && text.startsWith('\n')) {
          text = text.substring(1);
        }
        final String stripped = _stripGivenIndent(text, commonIndent);
        _writeReindented(stripped, expansionIndent);
      } else {
        node.accept(sub);
      }
      isFirst = false;
    }
  }

  String _renderNodesToString(
    List<Node> nodes, [
    Map<String, String> blockIndentOverrides = const {},
  ]) {
    final buf = StringBuffer();
    final sub = Renderer(
      buf,
      _stack,
      lenient,
      htmlEscapeValues,
      partialResolver,
      templateName,
      '',
      source,
      blockOverrides: _blockOverrides,
      blockIndentOverrides: blockIndentOverrides.isNotEmpty
          ? blockIndentOverrides
          : _blockIndentOverrides,
    );
    for (final n in nodes) {
      n.accept(sub);
    }
    return buf.toString();
  }

  /// Returns the minimum leading whitespace of non-empty lines (intrinsic indent).
  static String _computeIndentFromContent(List<Node> nodes) {
    final String raw = _staticRenderNodesToText(nodes);
    return _getCommonIndent(raw);
  }

  static String _staticRenderNodesToText(List<Node> nodes) {
    final buf = StringBuffer();
    for (final n in nodes) {
      if (n is TextNode) {
        buf.write(n.text);
      }
      // Other node types would need a full renderer; for indent we only need text.
    }
    return buf.toString();
  }

  static String _getCommonIndent(String s) {
    final List<String> lines = s.split('\n');
    int? minIndent;
    String? sampleLine;
    for (final line in lines) {
      if (line.trim().isEmpty) {
        continue;
      }
      final int leading = line.length - line.trimLeft().length;
      if (minIndent == null || leading < minIndent) {
        minIndent = leading;
        sampleLine = line;
      }
    }
    if (minIndent == null || minIndent == 0 || sampleLine == null) {
      return '';
    }
    return sampleLine.substring(0, minIndent);
  }

  static String _stripGivenIndent(String s, String indent) {
    if (indent.isEmpty) {
      return s;
    }
    final int n = indent.length;
    return s.split('\n').map((String line) {
      if (line.trim().isEmpty) {
        return line;
      }
      if (line.length >= n && line.startsWith(indent)) {
        return line.substring(n);
      }
      return line;
    }).join('\n');
  }

  static String _stripCommonIndent(String s) {
    return _stripGivenIndent(s, _getCommonIndent(s));
  }

  void _writeReindented(String content, String expansionIndent) {
    if (expansionIndent.isEmpty) {
      write(content);
      return;
    }
    if (content.isEmpty) {
      return;
    }
    final List<String> lines = content.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) {
        write('\n');
      }
      final String line = lines[i];
      // Only add indent to non-empty lines (spec: don't indent blank lines).
      if (line.isNotEmpty) {
        write(expansionIndent);
      }
      write(line);
    }
  }

  // Walks up the stack looking for the variable.
  // Handles dotted names of the form "a.b.c".
  Object? resolveValue(String name) {
    if (name == '.') {
      return _stack.last;
    }
    final List<String> parts = name.split('.');
    Object? object = noSuchProperty;
    for (final Object? o in _stack.reversed) {
      object = _getNamedProperty(o, parts[0]);
      if (object != noSuchProperty) {
        break;
      }
    }
    for (var i = 1; i < parts.length; i++) {
      if (object == noSuchProperty) {
        return noSuchProperty;
      }
      object = _getNamedProperty(object, parts[i]);
    }
    return object;
  }

  // Returns the property of the given object by name. For a map,
  // which contains the key name, this is object[name]. For other
  // objects, this is object.name or object.name(). If no property
  // by the given name exists, this method returns noSuchProperty.
  Object? _getNamedProperty(dynamic object, String name) {
    if (object is Map && object.containsKey(name)) {
      return object[name];
    }

    if (object is List && _integerTag.hasMatch(name)) {
      final int index = int.parse(name);
      if (object.length > index) {
        return object[index];
      }
    }
    return noSuchProperty;
  }

  m.TemplateException error(String message, Node node) =>
      TemplateException(message, templateName, source, node.start);

  static const Map<int, String> _htmlEscapeMap = <int, String>{
    _AMP: '&amp;',
    _LT: '&lt;',
    _GT: '&gt;',
    _QUOTE: '&quot;',
    _APOS: '&#x27;',
    _FORWARD_SLASH: '&#x2F;',
  };

  String _htmlEscape(String s) {
    final buffer = StringBuffer();
    var startIndex = 0;
    var i = 0;
    for (final int c in s.runes) {
      if (c == _AMP ||
          c == _LT ||
          c == _GT ||
          c == _QUOTE ||
          c == _APOS ||
          c == _FORWARD_SLASH) {
        buffer.write(s.substring(startIndex, i));
        buffer.write(_htmlEscapeMap[c]);
        startIndex = i + 1;
      }
      i++;
    }
    buffer.write(s.substring(startIndex));
    return buffer.toString();
  }
}

const int _AMP = 38;
const int _LT = 60;
const int _GT = 62;
const int _QUOTE = 34;
const int _APOS = 39;
const int _FORWARD_SLASH = 47;
const int _NEWLINE = 10;
