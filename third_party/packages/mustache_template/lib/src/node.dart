// TODO(stuartmorgan): Remove this. See https://github.com/flutter/flutter/issues/174722.
// ignore_for_file: public_member_api_docs

abstract class Node {
  Node(this.start, this.end, this.parent);

  // The offset of the start of the token in the file. Unless this is a section
  // or inverse section, then this stores the start of the content of the
  // section.
  final int start;
  final int end;
  final Node? parent;

  void accept(Visitor visitor);
  void visitChildren(Visitor visitor) {}
}

abstract class Visitor {
  void visitText(TextNode node);
  void visitVariable(VariableNode node);
  void visitSection(SectionNode node);
  void visitPartial(PartialNode node);
  void visitParent(ParentNode node);
  void visitBlock(BlockNode node);
}

class TextNode extends Node {
  TextNode(this.text, int start, int end, Node? parent) : super(start, end, parent);

  String text;

  @override
  String toString() => '(TextNode "$_debugText" $start $end)';

  String get _debugText {
    final String t = text.replaceAll('\n', r'\n');
    return t.length < 50 ? t : '${t.substring(0, 48)}...';
  }

  @override
  void accept(Visitor visitor) => visitor.visitText(this);
}

class VariableNode extends Node {
  VariableNode(this.name, int start, int end, Node? parent, {this.escape = true, this.intrinsicIndent = ''})
    : super(start, end, parent);

  final String name;

  /// The intrinsic indentation of the variable node's parent, if any, to be removed from the resolved value
  /// prior to rendering.
  String intrinsicIndent;
  final bool escape;

  @override
  void accept(Visitor visitor) => visitor.visitVariable(this);

  @override
  String toString() => '(VariableNode "$name" escape: $escape $start $end)';
}

abstract class ContainerNode extends Node {
  ContainerNode(super.start, super.end, super.parent);

  String get name;
  List<Node> get children;

  bool startClearLeft = false;
  bool startClearRight = false;
  bool endClearLeft = false;
  bool endClearRight = false;

  /// Is the opening tag of this container standalone?
  ///
  /// A standalone tag is one where the tag is clear on both sides, i.e.
  /// surrounded by nothing but whitespace on its line.
  bool get isStartStandalone => startClearLeft && startClearRight;
  /// Is the closing tag of this container standalone?
  ///
  /// A standalone tag is one where the tag is clear on both sides, i.e.
  /// surrounded by nothing but whitespace on its line.
  bool get isEndStandalone => endClearLeft && endClearRight;
  /// Is the container as a whole standalone?
  ///
  /// A standalone container is one where the container is clear on both sides, i.e.
  /// there is nothing but whitespace to the left of the start tag and to the right
  /// of the end tag on their respective lines.
  bool get isContainerStandalone => startClearLeft && endClearRight;

  /// Is the container inner standalone?
  ///
  /// An inner standalone container considers only the inside clearance of the tag pair
  /// (right clearance for the start tag, left clearance for the end tag). Since argument
  /// blocks inside parent tags live in 'comment space' (their exterior indentation doesn't
  /// matter; they're always substituted in somewhere else), only the inside clearance
  /// matters to determine how we should treat the following lines.
  bool get isInnerStandalone => startClearRight && endClearLeft;

  @override
  void visitChildren(Visitor visitor) {
    for (final Node node in children) {
      node.accept(visitor);
    }
  }
}

class SectionNode extends ContainerNode {
  SectionNode(
    this.name,
    int start,
    int end,
    Node? parent,
    this.delimiters, {
    this.inverse = false,
  }) : contentStart = end,
       super(start, end, parent);

  @override
  final String name;
  final String delimiters;
  final bool inverse;
  final int contentStart;
  int? contentEnd; // Set in parser when close tag is parsed.
  @override
  final List<Node> children = <Node>[];

  @override
  void accept(Visitor visitor) => visitor.visitSection(this);

  @override
  String toString() => '(SectionNode $name inverse: $inverse $start $end)';
}

class ParentNode extends ContainerNode {
  ParentNode(this.name, int start, int end, this.indent, Node? parent) : super(start, end, parent);

  @override
  final String name;

  // Used to store the preceding whitespace before a parent tag, so that
  // its content can be correctly indented (standalone parent behavior).
  final String indent;

  @override
  final List<Node> children = <Node>[];

  @override
  void accept(Visitor visitor) => visitor.visitParent(this);

  @override
  String toString() => '(ParentNode $name $start $end "$indent")';
}

class BlockNode extends ContainerNode {
  BlockNode(this.name, int start, int end, Node? parent, {this.indent = ''})
    : super(start, end, parent) {
      Node? parent = this.parent;
      while (parent != null) {
        if (parent is ParentNode) {
          isArgument = true;
          break;
        }
        parent = parent.parent;
      }
    }

  @override
  final String name;

  /// When the block tag is standalone, preceding whitespace is stored so that
  /// override content can be reindented to match the expansion site.
  ///
  /// May be set in either the first pass of the parser, or in the second
  /// standalone/whitespace pass.
  String indent;

  @override
  final List<Node> children = <Node>[];

  /// Whether this block node is an argument block within a {{<parent}} tag,
  /// to be rendered in place of a parameter block in the parent template.
  bool isArgument = false;

  /// Whether this block node is a parameter block within a template, to be
  /// replaced by an argument block in a child template.
  bool get isParameter => !isArgument;

  /// If this block is a parameter block, and it is replaced by an argument block,
  /// this field will be set to the value of the argument block when the parameter
  /// block selects its replacement.
  BlockNode? replacedWith;

  @override
  void accept(Visitor visitor) => visitor.visitBlock(this);

  @override
  String toString() => '(BlockNode $name $start $end)';
}

class PartialNode extends Node {
  PartialNode(this.name, int start, int end, this.indent, Node? parent) : super(start, end, parent);

  final String name;

  // Used to store the preceding whitespace before a partial tag, so that
  // it's content can be correctly indented.
  final String indent;

  @override
  void accept(Visitor visitor) => visitor.visitPartial(this);

  @override
  String toString() => '(PartialNode $name $start $end "$indent")';
}
