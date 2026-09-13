import Foundation

/// The JavaScript half of the scripting API: the object model a script sees
/// (`brushy`, `Doc`, `Layer`, `Group`), implemented over one host function
/// that ships JSON operations to `ScriptSession`. Keeping the ergonomics in
/// JavaScript means the Swift side stays a flat, testable op interpreter and
/// the `.d.ts` in `ScriptAPIDeclaration` documents exactly what runs.
///
/// State is cached per document and invalidated by any mutation, so a loop
/// that only writes never re-reads, and a read after a write is fresh.
enum ScriptPrelude {
    static let source = #"""
(function (global) {
  "use strict";
  const host = global.__brushyHost;

  function call(op, args) {
    const raw = host.call(JSON.stringify(Object.assign({ op: op }, args || {})));
    const res = JSON.parse(raw);
    if (res && res.__error) throw new Error(res.__error);
    return res.value;
  }

  function refOf(x, what) {
    if (x === null || x === undefined) throw new Error("Missing " + (what || "layer"));
    if (typeof x === "object" && typeof x.id === "string") return x.id;
    return String(x);
  }
  function refsOf(list, what) {
    if (!Array.isArray(list)) list = [list];
    return list.map(function (x) { return refOf(x, what); });
  }
  function rectArgs(rect) {
    if (!rect || typeof rect !== "object") throw new Error("Expected a rect {x, y, width, height}");
    return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
  }
  function pick(obj, keys) {
    const out = {};
    if (!obj) return out;
    keys.forEach(function (k) { if (obj[k] !== undefined) out[k] = obj[k]; });
    return out;
  }

  const docs = {};

  class Layer {
    constructor(doc, id) { this._doc = doc; this.id = id; }
    get _s() { return this._doc._layerState(this.id); }
    _op(op, args) { return this._doc._op(op, Object.assign({ layer: this.id }, args || {})); }

    get name() { return this._s.name; }
    set name(v) { this._op("setLayer", { name: String(v) }); }
    get kind() { return this._s.kind; }
    get index() { return this._s.index; }
    get visible() { return this._s.visible; }
    set visible(v) { this._op("setLayer", { visible: !!v }); }
    get opacity() { return this._s.opacity; }
    set opacity(v) { this._op("setLayer", { opacity: Number(v) }); }
    get blendMode() { return this._s.blendMode; }
    set blendMode(v) { this._op("setLayer", { blendMode: String(v) }); }
    get clipped() { return this._s.clipped; }
    set clipped(v) { this._op("setLayer", { clipped: !!v }); }
    get group() { const g = this._s.group; return g ? new Group(this._doc, g) : null; }
    get frame() { return Object.assign({}, this._s.frame); }
    set frame(r) { this._op("setFrame", rectArgs(r)); }
    get x() { return this._s.frame.x; }
    set x(v) { this._op("setFrame", { x: Number(v) }); }
    get y() { return this._s.frame.y; }
    set y(v) { this._op("setFrame", { y: Number(v) }); }
    get width() { return this._s.frame.width; }
    set width(v) { this._op("setFrame", { width: Number(v) }); }
    get height() { return this._s.frame.height; }
    set height(v) { this._op("setFrame", { height: Number(v) }); }
    get right() { const f = this._s.frame; return f.x + f.width; }
    get bottom() { const f = this._s.frame; return f.y + f.height; }
    get centerX() { const f = this._s.frame; return f.x + f.width / 2; }
    get centerY() { const f = this._s.frame; return f.y + f.height / 2; }
    get rotation() { return this._s.rotation; }
    get sourceWidth() { return this._s.sourceWidth; }
    get sourceHeight() { return this._s.sourceHeight; }
    get hasMask() { return this._s.hasMask; }
    get paintable() { return this._s.paintable; }
    get text() { return this._s.text ? Object.assign({}, this._s.text) : null; }
    set text(v) { this.setText(typeof v === "string" ? { text: v } : v); }
    get shape() { return this._s.shape ? Object.assign({}, this._s.shape) : null; }
    set shape(v) { this.setShape(v); }

    move(dx, dy) { this._op("move", { dx: Number(dx) || 0, dy: Number(dy) || 0 }); return this; }
    moveTo(x, y) { this._op("setFrame", { x: Number(x), y: Number(y) }); return this; }
    resize(width, height) {
      const f = this._s.frame;
      if (width === undefined && height === undefined) throw new Error("resize needs a width, a height, or both");
      if (width === undefined) width = f.width * (Number(height) / f.height);
      if (height === undefined) height = f.height * (Number(width) / f.width);
      this._op("setFrame", { width: Number(width), height: Number(height) });
      return this;
    }
    scale(factor) {
      const f = this._s.frame;
      const k = Number(factor);
      const w = f.width * k, h = f.height * k;
      this._op("setFrame", { x: f.x + (f.width - w) / 2, y: f.y + (f.height - h) / 2, width: w, height: h });
      return this;
    }
    fitWithin(width, height) {
      const f = this._s.frame;
      const k = Math.min(Number(width) / f.width, Number(height) / f.height);
      this._op("setFrame", { width: f.width * k, height: f.height * k });
      return this;
    }
    rotate(degrees) { this._op("rotate", { degrees: Number(degrees) }); return this; }
    flip(axis) { this._op("flip", { axis: axis || "horizontal" }); return this; }
    duplicate(name) {
      const r = this._op("duplicate", name !== undefined ? { name: String(name) } : {});
      return new Layer(this._doc, r.id);
    }
    delete() { this._op("delete", {}); }
    remove() { this.delete(); }
    bringToFront() { this._op("reorder", { to: "front" }); return this; }
    sendToBack() { this._op("reorder", { to: "back" }); return this; }
    moveUp() { this._op("reorder", { to: "up" }); return this; }
    moveDown() { this._op("reorder", { to: "down" }); return this; }
    moveAbove(other) { this._op("reorder", { above: refOf(other) }); return this; }
    moveBelow(other) { this._op("reorder", { below: refOf(other) }); return this; }
    setText(props) {
      if (typeof props === "string") props = { text: props };
      this._op("setText", pick(props, ["text", "fontName", "fontSize", "color"]));
      return this;
    }
    setShape(props) {
      this._op("setShape", pick(props, ["kind", "fill", "stroke", "strokeWidth", "strokeStyle", "arrowStart", "arrowEnd"]));
      return this;
    }
    addMask(from) { this._op("addMask", { from: from || "selection" }); return this; }
    removeMask() { this._op("removeMask", {}); return this; }
    fill(color) { this._op("fill", { color: color }); return this; }
    fillGradient(opts) {
      if (Array.isArray(opts)) opts = { stops: opts };
      this._op("fillGradient", pick(opts, ["stops", "from", "to", "shape"]));
      return this;
    }
    draw(fn) {
      if (typeof fn !== "function") throw new Error("draw(fn) takes a function: layer.draw(ctx => { ... })");
      const ctx = new DrawingContext(this._doc);
      fn(ctx);
      if (ctx._commands.length) this._op("draw", { commands: ctx._commands });
      return this;
    }
    toJSON() { return this._s; }
    toString() { const s = this._s; return s.id + ' "' + s.name + '"'; }
  }

  // Records a subset of the HTML Canvas 2D API; Layer.draw replays it in
  // one op. Property sets are recorded too, so state is replayed in order.
  class CanvasGradient {
    constructor(kind, coords) { this._g = Object.assign({ kind: kind, stops: [] }, coords); }
    addColorStop(offset, color) { this._g.stops.push([Number(offset), color]); }
    toJSON() { return this._g; }
  }
  class DrawingContext {
    constructor(doc) {
      this._doc = doc;
      this._commands = [];
      this._state = { fillStyle: "#000000", strokeStyle: "#000000", lineWidth: 1, lineCap: "butt",
        lineJoin: "miter", globalAlpha: 1, font: "10px sans-serif", textAlign: "left", textBaseline: "alphabetic" };
      this.canvas = { width: doc.width, height: doc.height };
    }
    _rec(name, args) { this._commands.push([name].concat(args)); return this; }
    _num(args) { return Array.prototype.map.call(args, function (v) { return typeof v === "boolean" ? v : Number(v); }); }
    get fillStyle() { return this._state.fillStyle; }
    set fillStyle(v) { this._state.fillStyle = v; this._rec("fillStyle", [v instanceof CanvasGradient ? v : String(v)]); }
    get strokeStyle() { return this._state.strokeStyle; }
    set strokeStyle(v) { this._state.strokeStyle = v; this._rec("strokeStyle", [v instanceof CanvasGradient ? v : String(v)]); }
    get lineWidth() { return this._state.lineWidth; }
    set lineWidth(v) { this._state.lineWidth = Number(v); this._rec("lineWidth", [Number(v)]); }
    get lineCap() { return this._state.lineCap; }
    set lineCap(v) { this._state.lineCap = String(v); this._rec("lineCap", [String(v)]); }
    get lineJoin() { return this._state.lineJoin; }
    set lineJoin(v) { this._state.lineJoin = String(v); this._rec("lineJoin", [String(v)]); }
    get globalAlpha() { return this._state.globalAlpha; }
    set globalAlpha(v) { this._state.globalAlpha = Number(v); this._rec("globalAlpha", [Number(v)]); }
    get font() { return this._state.font; }
    set font(v) { this._state.font = String(v); this._rec("font", [String(v)]); }
    get textAlign() { return this._state.textAlign; }
    set textAlign(v) { this._state.textAlign = String(v); this._rec("textAlign", [String(v)]); }
    get textBaseline() { return this._state.textBaseline; }
    set textBaseline(v) { this._state.textBaseline = String(v); this._rec("textBaseline", [String(v)]); }
    setLineDash(segments) { return this._rec("setLineDash", [Array.from(segments || []).map(Number)]); }
    save() { return this._rec("save", []); }
    restore() { return this._rec("restore", []); }
    translate(x, y) { return this._rec("translate", this._num([x, y])); }
    rotate(angle) { return this._rec("rotate", this._num([angle])); }
    scale(x, y) { return this._rec("scale", this._num([x, y === undefined ? x : y])); }
    transform(a, b, c, d, e, f) { return this._rec("transform", this._num([a, b, c, d, e, f])); }
    setTransform(a, b, c, d, e, f) { return this._rec("setTransform", this._num([a, b, c, d, e, f])); }
    resetTransform() { return this._rec("resetTransform", []); }
    fillRect(x, y, w, h) { return this._rec("fillRect", this._num([x, y, w, h])); }
    strokeRect(x, y, w, h) { return this._rec("strokeRect", this._num([x, y, w, h])); }
    clearRect(x, y, w, h) { return this._rec("clearRect", this._num([x, y, w, h])); }
    beginPath() { return this._rec("beginPath", []); }
    closePath() { return this._rec("closePath", []); }
    moveTo(x, y) { return this._rec("moveTo", this._num([x, y])); }
    lineTo(x, y) { return this._rec("lineTo", this._num([x, y])); }
    rect(x, y, w, h) { return this._rec("rect", this._num([x, y, w, h])); }
    roundRect(x, y, w, h, r) { return this._rec("roundRect", this._num([x, y, w, h, Array.isArray(r) ? r[0] : (r || 0)])); }
    arc(x, y, r, start, end, anticlockwise) { return this._rec("arc", this._num([x, y, r, start, end, !!anticlockwise])); }
    ellipse(x, y, rx, ry, rotation, start, end, anticlockwise) {
      return this._rec("ellipse", this._num([x, y, rx, ry, rotation || 0, start, end, !!anticlockwise]));
    }
    quadraticCurveTo(cx, cy, x, y) { return this._rec("quadraticCurveTo", this._num([cx, cy, x, y])); }
    bezierCurveTo(c1x, c1y, c2x, c2y, x, y) { return this._rec("bezierCurveTo", this._num([c1x, c1y, c2x, c2y, x, y])); }
    fill() { return this._rec("fill", []); }
    stroke() { return this._rec("stroke", []); }
    clip(rule) { return this._rec("clip", rule ? [String(rule)] : []); }
    fillText(text, x, y) { return this._rec("fillText", [String(text)].concat(this._num([x, y]))); }
    strokeText(text, x, y) { return this._rec("strokeText", [String(text)].concat(this._num([x, y]))); }
    measureText(text) { return call("measureText", { text: String(text), font: this._state.font }); }
    createLinearGradient(x0, y0, x1, y1) {
      return new CanvasGradient("linear", { x0: Number(x0), y0: Number(y0), x1: Number(x1), y1: Number(y1) });
    }
    createRadialGradient(x0, y0, r0, x1, y1, r1) {
      return new CanvasGradient("radial", { x0: Number(x0), y0: Number(y0), r0: Number(r0), x1: Number(x1), y1: Number(y1), r1: Number(r1) });
    }
  }

  class Group {
    constructor(doc, id) { this._doc = doc; this.id = id; }
    get _s() { return this._doc._groupState(this.id); }
    _op(op, args) { return this._doc._op(op, Object.assign({ group: this.id }, args || {})); }
    get name() { return this._s.name; }
    set name(v) { this._op("setGroup", { name: String(v) }); }
    get visible() { return this._s.visible; }
    set visible(v) { this._op("setGroup", { visible: !!v }); }
    get opacity() { return this._s.opacity; }
    set opacity(v) { this._op("setGroup", { opacity: Number(v) }); }
    get blendMode() { return this._s.blendMode; }
    set blendMode(v) { this._op("setGroup", { blendMode: v === null ? null : String(v) }); }
    get parent() { const p = this._s.parent; return p ? new Group(this._doc, p) : null; }
    get layers() {
      const id = this.id;
      return this._doc.layers.filter(function (l) { return l._s.group === id; });
    }
    ungroup() { this._op("ungroup", {}); }
    delete() { this._op("deleteGroup", {}); }
    toJSON() { return this._s; }
  }

  class Doc {
    constructor(id) { this.id = id; this._state = null; }
    _op(op, args) {
      const r = call(op, Object.assign({ doc: this.id }, args || {}));
      this._state = null;
      return r;
    }
    _refresh() { if (!this._state) this._state = call("state", { doc: this.id }); return this._state; }
    _layerState(id) {
      const s = this._refresh();
      for (let i = 0; i < s.layers.length; i++) if (s.layers[i].id === id) return s.layers[i];
      throw new Error("Layer " + id + " no longer exists in " + this.id);
    }
    _groupState(id) {
      const s = this._refresh();
      for (let i = 0; i < s.groups.length; i++) if (s.groups[i].id === id) return s.groups[i];
      throw new Error("Group " + id + " no longer exists in " + this.id);
    }
    _layerRef(x) {
      if (x instanceof Layer) return x.id;
      const ref = refOf(x);
      const s = this._refresh();
      for (let i = s.layers.length - 1; i >= 0; i--) if (s.layers[i].id === ref) return ref;
      for (let i = s.layers.length - 1; i >= 0; i--) if (s.layers[i].name === ref) return s.layers[i].id;
      const lower = ref.toLowerCase();
      for (let i = s.layers.length - 1; i >= 0; i--) if (s.layers[i].name.toLowerCase() === lower) return s.layers[i].id;
      return ref;
    }

    get title() { return this._refresh().title; }
    get width() { return this._refresh().width; }
    get height() { return this._refresh().height; }
    get layers() {
      const self = this;
      return this._refresh().layers.map(function (l) { return new Layer(self, l.id); });
    }
    get groups() {
      const self = this;
      return this._refresh().groups.map(function (g) { return new Group(self, g.id); });
    }
    get selection() { const s = this._refresh().selection; return s ? Object.assign({}, s) : null; }
    get selectedLayers() {
      const self = this;
      return this._refresh().selectedLayers.map(function (id) { return new Layer(self, id); });
    }
    layer(ref) {
      if (ref instanceof Layer) return ref;
      const id = this._layerRef(ref);
      try { this._layerState(id); } catch (e) { return null; }
      return new Layer(this, id);
    }
    group(ref) {
      if (ref instanceof Group) return ref;
      const s = this._refresh();
      const key = refOf(ref, "group");
      for (let i = 0; i < s.groups.length; i++) if (s.groups[i].id === key || s.groups[i].name === key) return new Group(this, s.groups[i].id);
      return null;
    }
    findLayers(pattern) {
      const re = pattern instanceof RegExp ? pattern : new RegExp(String(pattern), "i");
      return this.layers.filter(function (l) { return re.test(l.name); });
    }
    visibleLayers() { return this.layers.filter(function (l) { return l.visible; }); }

    resizeCanvas(width, height, anchor) {
      const args = { anchor: anchor || "center" };
      if (width !== undefined && width !== null) args.width = Number(width);
      if (height !== undefined && height !== null) args.height = Number(height);
      this._op("resizeCanvas", args); return this;
    }
    crop(rect) { this._op("crop", rectArgs(rect)); return this; }
    scaleImage(width, height) {
      const args = {};
      if (width !== undefined && width !== null) args.width = Number(width);
      if (height !== undefined && height !== null) args.height = Number(height);
      this._op("scaleImage", args); return this;
    }
    fitCanvasToContent(padding) { this._op("fitCanvasToContent", { padding: Number(padding) || 0 }); return this; }

    addText(text, opts) {
      const args = Object.assign({ text: String(text) }, pick(opts, ["x", "y", "fontName", "fontSize", "color", "name", "above"]));
      if (args.above !== undefined) args.above = this._layerRef(args.above);
      return new Layer(this, this._op("addTextLayer", args).id);
    }
    addShape(kind, rect, opts) {
      const args = Object.assign({ kind: kind }, rectArgs(rect),
        pick(opts, ["fill", "stroke", "strokeWidth", "strokeStyle", "name", "above"]));
      if (args.above !== undefined) args.above = this._layerRef(args.above);
      return new Layer(this, this._op("addShapeLayer", args).id);
    }
    addRectangle(rect, opts) { return this.addShape("rectangle", rect, opts); }
    addEllipse(rect, opts) { return this.addShape("ellipse", rect, opts); }
    addLine(x1, y1, x2, y2, opts) {
      const args = Object.assign({ kind: "line", x1: x1, y1: y1, x2: x2, y2: y2 },
        pick(opts, ["stroke", "strokeWidth", "strokeStyle", "arrowStart", "arrowEnd", "name", "above"]));
      if (args.above !== undefined) args.above = this._layerRef(args.above);
      return new Layer(this, this._op("addShapeLayer", args).id);
    }
    addLayer(opts) {
      if (typeof opts === "string") opts = { name: opts };
      const args = pick(opts, ["name", "color", "x", "y", "width", "height", "above"]);
      if (args.above !== undefined) args.above = this._layerRef(args.above);
      return new Layer(this, this._op("addLayer", args).id);
    }
    addImage(image, opts) {
      const args = Object.assign({ image: refOf(image, "image") },
        pick(opts, ["x", "y", "width", "height", "stretch", "name", "above"]));
      if (args.above !== undefined) args.above = this._layerRef(args.above);
      return new Layer(this, this._op("addImageLayer", args).id);
    }

    group(layers, name) {
      const args = { layers: refsOf(layers).map(this._layerRef, this) };
      if (name !== undefined) args.name = String(name);
      return new Group(this, this._op("group", args).id);
    }
    arrange(layers, opts) {
      const args = Object.assign({ layers: refsOf(layers).map(this._layerRef, this) },
        pick(opts, ["direction", "gap", "align", "x", "y"]));
      this._op("arrange", args); return this;
    }
    align(layers, edge, to) {
      this._op("align", { layers: refsOf(layers).map(this._layerRef, this), edge: edge, to: to || "canvas" }); return this;
    }
    distribute(layers, axis, mode) {
      this._op("distribute", { layers: refsOf(layers).map(this._layerRef, this), axis: axis || "horizontal", mode: mode || "spacing" }); return this;
    }
    select(rect) {
      if (rect === null || rect === undefined) this._op("deselect", {});
      else this._op("select", rectArgs(rect));
      return this;
    }
    selectAll() { this._op("selectAll", {}); return this; }
    deselect() { this._op("deselect", {}); return this; }
    invertSelection() { this._op("invertSelection", {}); return this; }
    selectLayers(layers) { this._op("setSelectedLayers", { layers: refsOf(layers).map(this._layerRef, this) }); return this; }
    copyLayersTo(layers, doc, opts) {
      const target = doc instanceof Doc ? doc.id : String(doc);
      const args = Object.assign({ layers: refsOf(layers).map(this._layerRef, this), to: target }, pick(opts, ["x", "y"]));
      const ids = this._op("copyLayers", args);
      const t = brushy.doc(target);
      t._state = null;
      return ids.map(function (id) { return new Layer(t, id); });
    }
    describe() { return call("describe", { doc: this.id }); }
    toJSON() { return this._refresh(); }
    toString() { return this.describe(); }
  }

  function docFor(id) {
    if (!docs[id]) docs[id] = new Doc(id);
    return docs[id];
  }

  const brushy = {
    get documents() { return call("documents").map(function (d) { return docFor(d.id); }); },
    get document() { const id = call("activeDocument"); return id ? docFor(id) : null; },
    doc: function (id) {
      if (id instanceof Doc) return id;
      const found = call("documents").filter(function (d) { return d.id === id || d.title === id; });
      if (!found.length) throw new Error("No open document \"" + id + "\"");
      return docFor(found[0].id);
    },
    newDocument: function (width, height, name) {
      const args = { width: Number(width), height: Number(height) };
      if (name !== undefined) args.name = String(name);
      const id = call("newDocument", args).id;
      return docFor(id);
    },
    loadImage: function (path) { return call("loadImage", { path: String(path) }); },
    Layer: Layer, Group: Group, Doc: Doc,
  };

  function format(v) {
    if (typeof v === "string") return v;
    if (v === undefined) return "undefined";
    if (v instanceof Error) return String(v.stack || v.message);
    try { return JSON.stringify(v, null, 0); } catch (e) { return String(v); }
  }
  const console = {
    log: function () { host.log(Array.prototype.map.call(arguments, format).join(" ")); },
  };
  console.info = console.log; console.warn = console.log; console.error = console.log; console.debug = console.log;

  global.brushy = brushy;
  global.console = console;
  Object.defineProperty(global, "doc", { get: function () { return brushy.document; }, configurable: true });
  global.__brushyRun = function (fn) {
    const v = fn();
    if (v === undefined) return "null";
    try { return JSON.stringify(v); } catch (e) { return JSON.stringify(String(v)); }
  };
})(this);
"""#
}
