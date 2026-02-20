// TODO(stuartmorgan): Remove this. See https://github.com/flutter/flutter/issues/174722.
// ignore_for_file: public_member_api_docs

abstract class Node {
  Node(this.start, this.end);

  // The offset of the start of the token in the file. Unless this is a section
  // or inverse section, then this stores the start of the content of the
  // section.
  final int start;
  final int end;

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
  TextNode(this.text, int start, int end) : super(start, end);

  final String text;

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
  VariableNode(this.name, int start, int end, {this.escape = true})
    : super(start, end);

  final String name;
  final bool escape;

  @override
  void accept(Visitor visitor) => visitor.visitVariable(this);

  @override
  String toString() => '(VariableNode "$name" escape: $escape $start $end)';
}

abstract class ContainerNode extends Node {
  ContainerNode(super.start, super.end);

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
    this.delimiters, {
    this.inverse = false,
  }) : contentStart = end,
       super(start, end);

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
  ParentNode(this.name, int start, int end, this.indent) : super(start, end);

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
  BlockNode(this.name, int start, int end, {this.indent = ''})
    : super(start, end);

  @override
  final String name;

  /// When the block tag is standalone, preceding whitespace is stored so that
  /// override content can be reindented to match the expansion site.
  final String indent;

  @override
  final List<Node> children = <Node>[];

  @override
  void accept(Visitor visitor) => visitor.visitBlock(this);

  @override
  String toString() => '(BlockNode $name $start $end)';
}

class PartialNode extends Node {
  PartialNode(this.name, int start, int end, this.indent) : super(start, end);

  final String name;

  // Used to store the preceding whitespace before a partial tag, so that
  // it's content can be correctly indented.
  final String indent;

  @override
  void accept(Visitor visitor) => visitor.visitPartial(this);

  @override
  String toString() => '(PartialNode $name $start $end "$indent")';
}
