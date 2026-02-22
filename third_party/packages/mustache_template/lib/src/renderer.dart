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
    this.implicitIndent = '',
    Map<String, BlockNode> blockOverrides = const {},
  }) : _stack = List<Object?>.from(stack),
       _blockOverrides = blockOverrides;

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
    Map<String, BlockNode> blockOverrides
  ) : this(
         ctx.sink,
         ctx._stack,
         ctx.lenient,
         ctx.htmlEscapeValues,
         ctx.partialResolver,
         ctx.templateName,
         ctx.indent + indent,
         parent.source,
         blockOverrides: blockOverrides,
       );

  Renderer.block(
    Renderer ctx,
    BlockNode block,
  ) : this(
         ctx.sink,
         ctx._stack,
         ctx.lenient,
         ctx.htmlEscapeValues,
         ctx.partialResolver,
         ctx.templateName,
         ctx.indent + block.indent,
         ctx.source,
         implicitIndent: block.indent,
         blockOverrides: ctx._blockOverrides,
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
  final String implicitIndent;
  final String source;
  final Map<String, BlockNode> _blockOverrides;

  void push(Object? value) => _stack.add(value);

  Object? pop() => _stack.removeLast();

  void write(Object output) => sink.write(output.toString());

  Node? lastNode;

  /// Render a list of nodes.
  ///
  /// If [writeInitialIndent] is true, the current indent will be written before the first node.
  /// (Note that some nodes handle their own indentation as either part of their visit methods, or
  /// because they create sub-renderers.)
  ///
  /// [argumentBlock] and [parameterBlock] must be provided if this is a block renderer and [nodes] is substituted
  /// from a child template. [parameterBlock] is the block in the current template that is being overridden by a child template.
  /// [argumentBlock] is the block in the child template that should be rendered in place of the parameter block in the current template.
  void render(List<Node> nodes, {bool writeInitialIndent = true}) {
    if (indent == '') {
      for (final n in nodes) {
        n.accept(this);
        lastNode = n;
      }
    } else if (nodes.isNotEmpty) {
      // Special case to make sure there is not an extra indent after the last
      // line in the partial file.
      if(writeInitialIndent) {
        write(indent);
      }

      int lastNonBlockNode = nodes.length - 1;
      for(int i = nodes.length - 2; i >= 0; i--) {
        if (nodes[i + 1] is BlockNode) {
          lastNonBlockNode = i;
        } else {
          break;
        }
      }

      // lastNode controls whether the last line of text prints an
      // indent on the following line if its last rune is a newline.
      // Since block nodes handle their own initial indentation, we
      // want to treat the last node that isn't a block node as lastNode.
      Node? previousNode;
      for(final (index, node) in nodes.indexed) {
        if (index > 0) {
          previousNode = nodes[index - 1];
        }

        if(node is TextNode) {
          _handleWhitespaceSpecialCases(node, previousNode);
        }
        if (index < lastNonBlockNode) {
          node.accept(this);
        } else {
          if (node is TextNode) {
            visitText(node, lastNode: true);
          } else {
            node.accept(this);
          }
        }
        lastNode = node;
      }
    }
  }

  void _handleWhitespaceSpecialCases(TextNode node, Node? previousNode) {
    if(node.text.trim().isEmpty) {
      // Never indent a whitespace-only text node (including newlines)
      return;
    }

    if(node.text.startsWith(_lineEndRegex)) {
      // Never add an indent before a text node that starts with a newline,
      // to avoid extra trailing whitespace after a previous text line, or
      // a line that is only whitespace followed by a newline.
      return;
    }

    final bool previousNodeIsStandaloneContainer = previousNode is ContainerNode && previousNode.isContainerStandalone;
    if(previousNodeIsStandaloneContainer) {
      write(indent);
    }

    // If the previous node is an inline parameter block (e.g. `text {{$block}}...{{/block}} text`),
    // and the argument block is standalone, the argument block's contents will probably write a newline, which
    // will add a line we didn't account for when parsing the text surrounding the parameter block—a text node
    // following a standalone argument block replacing an inline parameter block starts a new line. It also may
    // have leading whitespace from the gap between the close delimiter and the start of the following content.
    // So, we: 1. trim the text node's leading whitespace to get to the start of the line, 2. write the current
    // renderer's indent, and 3. write the text node's text, so it aligns with the current renderer's indent.
    if (previousNode is BlockNode && previousNode.isParameter) {
      final BlockNode? argumentBlock = previousNode.replacedWith;
      final bool argumentBlockStandalone = argumentBlock != null && argumentBlock.isInnerStandalone;
      final bool parameterBlockInline = !previousNode.isContainerStandalone;
      if(argumentBlockStandalone && parameterBlockInline) {
        node.text = node.text.trimLeft();
        write(indent);
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
    } else if (node.text.runes.last == _NEWLINE) {
      // Never indent following the final newline in a node.
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

      if (node.clearLeft) {
        write(indent + output);
      } else {
        write(output);
      }
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
    final overridesFromChild = <String, BlockNode>{};

    for (var i = 0; i < node.children.length; i++) {
      final Node child = node.children[i];
      if (child is BlockNode) {
        overridesFromChild[child.name] = child;
      }
    }
    // Merge with current overrides: existing (outer/descendant) overrides take precedence.
    final merged = Map<String, BlockNode>.from(
      _blockOverrides,
    );
    for (final MapEntry<String, BlockNode> e in overridesFromChild.entries) {
      merged.putIfAbsent(e.key, () => e.value);
    }
    final String parentName = node.name;
    final Template? template = partialResolver == null
        ? null
        : (partialResolver!(parentName) as Template?);
    if (template != null) {
      final List<Node> nodes = getTemplateNodes(template);
      final renderer = Renderer.parent(
        this,
        template,
        node.indent,
        merged,
      );

      renderer.render(nodes, writeInitialIndent: _shouldWriteInitialIndent(nodes));
    } else if (lenient) {
      // do nothing
    } else {
      throw error('Parent not found: $parentName.', node);
    }
  }

  /// Renders a block override. BlockNode is the block in the current template
  /// that is being overridden by a child template. renderNodes is the content
  /// from the child template that should be rendered in place of the block in
  /// the current template.
  @override
  void visitBlock(BlockNode node) {
    final BlockNode? overrideBlock = _blockOverrides[node.name];
    node.replacedWith = overrideBlock;
    final List<Node> renderNodes = overrideBlock?.children ?? node.children;

    final blockRenderer = Renderer.block(
      this,
      node,
    );
    blockRenderer.render(renderNodes,
      writeInitialIndent: _shouldWriteInitialIndent(renderNodes, container: node),
    );
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

  /// Returns true if the initial indent should be written before the first node in the list.
  /// This is true if the first node is not a BlockNode or VariableNode, both of which
  /// render their own indentation.
  bool _shouldWriteInitialIndent(List<Node> nodes, {ContainerNode? container}) {
    Node? firstMeaningfulNode;
    for(final node in nodes) {
      if (node is TextNode && node.text.isEmpty) {
        continue;
      }
      firstMeaningfulNode = node;
      break;
    }
    final bool childNeedsIndent = firstMeaningfulNode != null && firstMeaningfulNode is! BlockNode && firstMeaningfulNode is! VariableNode;

    final bool enclosingContainerStandalone;
    if (container != null) {
      if (container is BlockNode || container is ParentNode) {
        enclosingContainerStandalone = container.isContainerStandalone;
      } else {
        enclosingContainerStandalone = false;
      }
    } else {
      enclosingContainerStandalone = false;
    }

    return childNeedsIndent && (container == null || enclosingContainerStandalone);
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
final RegExp _lineEndRegex = RegExp(r'\r?\n');
