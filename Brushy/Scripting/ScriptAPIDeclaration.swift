import Foundation

/// The scripting API as a TypeScript declaration — what goes into a model's
/// system prompt (and what a human reads). Models read a `.d.ts` far more
/// reliably than prose or JSON schemas. Must stay in step with
/// `ScriptPrelude` and `ScriptSession`; `ScriptHostTests` exercises the
/// documented surface.
enum ScriptAPIDeclaration {
    static let source = #"""
// Brushy scripting API. Scripts run synchronously against a snapshot of the
// open documents; every change is applied atomically when the script
// returns (one undo step per document). If the script throws, nothing is
// applied. `return` a value to see it in the result. `console.log` works.
//
// COORDINATES: top-left origin, y grows DOWN, units are canvas pixels.
// A layer's `frame` is its axis-aligned bounding box on the canvas.
// Colours: "#rrggbb", "#rrggbbaa", "rgb(r, g, b)", CSS names, or {r,g,b,a} in 0–1.
// Blend modes: "normal" | "multiply" | "screen" | "overlay" | "darken" | "lighten" |
//   "color-dodge" | "color-burn" | "soft-light" | "hard-light" | "difference" |
//   "exclusion" | "hue" | "saturation" | "color" | "luminosity".

interface Rect { x: number; y: number; width: number; height: number }
type LayerRef = Layer | string;          // a Layer, its id ("l3fa9c1"), or its exact name
type Anchor = "center" | "top" | "bottom" | "left" | "right" |
              "top-left" | "top-right" | "bottom-left" | "bottom-right";

declare const brushy: {
  readonly document: Doc | null;          // the active (frontmost) document
  readonly documents: Doc[];              // every open document
  doc(id: string): Doc;                   // by id ("doc1") or title; throws if missing
  newDocument(width: number, height: number, name?: string): Doc;  // opens a new window on commit
  loadImage(path: string): { image: string; width: number; height: number }; // from disk, for doc.addImage
};
declare const doc: Doc;                   // shorthand for brushy.document

declare class Doc {
  readonly id: string;                    // "doc1"
  readonly title: string;
  readonly width: number;                 // canvas size in pixels
  readonly height: number;
  readonly layers: Layer[];               // bottom → top (index 0 renders first)
  readonly groups: Group[];
  readonly selection: Rect | null;        // marching-ants selection bounds, or null
  readonly selectedLayers: Layer[];       // what is highlighted in the Layers panel

  layer(ref: LayerRef): Layer | null;     // by id or exact name (topmost wins)
  group(ref: Group | string): Group | null;
  findLayers(pattern: string | RegExp): Layer[];   // name matches (case-insensitive)
  visibleLayers(): Layer[];

  // Canvas. None of these ever discard pixels; content outside the canvas survives.
  resizeCanvas(width?: number, height?: number, anchor?: Anchor): this;  // anchor default "center"
  crop(rect: Rect): this;
  scaleImage(width?: number, height?: number): this;   // scales everything; one dimension keeps aspect
  fitCanvasToContent(padding?: number): this;          // crop to the visible layers' bounds

  // New layers land on top of the stack (or directly above `above`) and become selected.
  addText(text: string, opts?: { x?: number; y?: number; fontSize?: number; fontName?: string;
          color?: string; name?: string; above?: LayerRef }): Layer;     // x,y = top-left of the text
  addShape(kind: "rectangle" | "ellipse", rect: Rect, opts?: ShapeStyle): Layer;
  addRectangle(rect: Rect, opts?: ShapeStyle): Layer;
  addEllipse(rect: Rect, opts?: ShapeStyle): Layer;
  addLine(x1: number, y1: number, x2: number, y2: number,
          opts?: ShapeStyle & { arrowStart?: boolean; arrowEnd?: boolean }): Layer;
  addLayer(opts?: { name?: string; color?: string; x?: number; y?: number; width?: number;
           height?: number; above?: LayerRef } | string): Layer;
      // A paintable raster layer: transparent and canvas-sized, or a solid colour block
      // at the given frame (default: whole canvas). addLayer({color: "white"}) = background.
  addImage(image: string, opts?: { x?: number; y?: number; width?: number; height?: number;
           stretch?: boolean; name?: string; above?: LayerRef }): Layer;
      // Places an image id from brushy.loadImage or the generate tool. Default: centred, scaled
      // down to fit. width/height fit the image inside that box keeping aspect (stretch: exact).

  // Layout. Translation only — nothing is resampled.
  arrange(layers: LayerRef[], opts?: { direction?: "horizontal" | "vertical"; gap?: number;
          align?: "start" | "center" | "end"; x?: number; y?: number }): this;
      // Lays the layers out in the order given, in a row (default) or column, `gap` px apart.
      // align is the cross-axis: top/center/bottom for rows, left/center/right for columns.
      // x,y = top-left of the whole run; default keeps its current top-left.
  align(layers: LayerRef[], edge: "left" | "centerX" | "right" | "top" | "centerY" | "bottom",
        to?: "canvas" | "selection"): this;   // "selection" = the layers' shared bounds
  distribute(layers: LayerRef[], axis: "horizontal" | "vertical",
             mode?: "spacing" | "centers"): this;   // ≥ 3 layers; "spacing" equalises gaps
  group(layers: LayerRef[], name?: string): Group;

  // Selection (the marquee). Ops like fill and addMask("selection") respect it.
  select(rect: Rect | null): this;
  selectAll(): this;
  deselect(): this;
  invertSelection(): this;
  selectLayers(layers: LayerRef[]): this;   // Layers-panel highlight

  copyLayersTo(layers: LayerRef[], target: Doc | string, opts?: { x?: number; y?: number }): Layer[];
  describe(): string;                       // compact text summary of the document
}

interface ShapeStyle {
  fill?: string | null;                     // default white; null = no fill
  stroke?: string | null;                   // default black; null = no stroke
  strokeWidth?: number;                     // default 4
  strokeStyle?: "solid" | "dashed" | "dotted";
  name?: string;
  above?: LayerRef;
}

declare class Layer {
  readonly id: string;                      // "l3fa9c1" — stable, use it to refer back
  name: string;
  readonly kind: "raster" | "text" | "shape" | "adjustment";
  readonly index: number;                   // 0 = bottom of the stack
  visible: boolean;
  opacity: number;                          // 0–1
  blendMode: string;
  clipped: boolean;                         // clipping mask onto the layer below
  readonly group: Group | null;

  frame: Rect;                              // canvas-space bounding box; setting moves AND resizes
  x: number; y: number;                     // top-left; setting moves (rotation kept)
  width: number; height: number;            // setting resizes that dimension only (rotation reset)
  readonly right: number; readonly bottom: number;
  readonly centerX: number; readonly centerY: number;
  readonly rotation: number;                // degrees clockwise
  readonly sourceWidth: number;             // native pixel size of the layer's image
  readonly sourceHeight: number;
  readonly hasMask: boolean;
  readonly paintable: boolean;              // true for layers made in Brushy; imported photos are not
  text: { text: string; fontName: string; fontSize: number; color: string } | null;  // text layers
  shape: { kind: "rectangle" | "ellipse" | "line"; fill: string | null; stroke: string | null;
           strokeWidth: number; strokeStyle: string } | null;                       // shape layers

  move(dx: number, dy: number): this;       // dy > 0 moves DOWN
  moveTo(x: number, y: number): this;       // top-left
  resize(width?: number, height?: number): this;  // one dimension keeps aspect ratio
  scale(factor: number): this;              // about the centre
  fitWithin(width: number, height: number): this; // scale down/up to fit a box, aspect kept
  rotate(degrees: number): this;            // clockwise, about the centre, cumulative
  flip(axis?: "horizontal" | "vertical"): this;
  duplicate(name?: string): Layer;          // lands directly above
  delete(): void;
  bringToFront(): this; sendToBack(): this; moveUp(): this; moveDown(): this;
  moveAbove(other: LayerRef): this; moveBelow(other: LayerRef): this;
  setText(props: string | { text?: string; fontName?: string; fontSize?: number; color?: string }): this;
  setShape(props: { fill?: string | null; stroke?: string | null; strokeWidth?: number;
           strokeStyle?: "solid" | "dashed" | "dotted" }): this;
  addMask(from?: "selection" | "reveal" | "hide"): this;  // "selection" (default) hides outside it
  removeMask(): this;
  fill(color: string): this;                // paintable layers only; inside the selection if any
  fillGradient(opts: GradientStops | { stops: GradientStops; from?: Point; to?: Point;
               shape?: "linear" | "radial" }): this;
      // Multi-stop gradient across a paintable layer (inside the selection if any). from/to are
      // canvas points, default top centre → bottom centre of the layer; the end colours clamp
      // beyond them. Full-canvas gradient background in one line:
      //   doc.addLayer("Background").fillGradient(["#1b1440", "#a23b89", "#ff9a66", "#fff3c4"])
      // NEVER build a gradient out of many thin layers.
  draw(fn: (ctx: DrawingContext) => void): this;
      // Draw pixels onto a paintable layer with a subset of the HTML Canvas 2D API, in ONE op.
      // Coordinates are canvas pixels (top-left origin) whatever the layer's frame; drawing
      // outside the layer's own pixels is clipped, so draw on a canvas-sized layer:
      //   doc.addLayer("Pattern").draw(ctx => {
      //     ctx.fillStyle = "#123456"; ctx.fillRect(0, 0, doc.width, doc.height);
      //     for (let i = 0; i < 10; i++) { ctx.beginPath(); ctx.arc(60 + i * 80, 60, 25, 0, Math.PI * 2); ctx.fill(); }
      //     ctx.font = "bold 40px Helvetica"; ctx.textAlign = "center"; ctx.fillText("Hi", doc.width / 2, 200);
      //   });
      // Use this for patterns, grids, charts, custom shapes — anything freeform. Fills and
      // strokes composite over what is already on the layer; the selection clips if there is one.
}

declare class DrawingContext {                // HTML Canvas 2D subset; same semantics as the browser
  readonly canvas: { width: number; height: number };   // the document's canvas size
  fillStyle: string | CanvasGradient;         // colours as above; default black
  strokeStyle: string | CanvasGradient;
  lineWidth: number; lineCap: "butt" | "round" | "square"; lineJoin: "miter" | "round" | "bevel";
  globalAlpha: number;                        // 0–1
  font: string;                               // CSS shorthand: "bold 24px Helvetica", "italic 12pt Georgia"
  textAlign: "left" | "center" | "right" | "start" | "end";
  textBaseline: "alphabetic" | "top" | "middle" | "bottom";
  setLineDash(segments: number[]): void;
  save(): void; restore(): void;              // styles, transform and clip
  translate(x: number, y: number): void; rotate(radians: number): void; scale(x: number, y?: number): void;
  transform(a: number, b: number, c: number, d: number, e: number, f: number): void;
  setTransform(a: number, b: number, c: number, d: number, e: number, f: number): void;
  resetTransform(): void;
  fillRect(x: number, y: number, w: number, h: number): void;
  strokeRect(x: number, y: number, w: number, h: number): void;
  clearRect(x: number, y: number, w: number, h: number): void;    // to transparent
  beginPath(): void; closePath(): void; moveTo(x: number, y: number): void; lineTo(x: number, y: number): void;
  rect(x: number, y: number, w: number, h: number): void;
  roundRect(x: number, y: number, w: number, h: number, radius: number): void;
  arc(x: number, y: number, r: number, startAngle: number, endAngle: number, anticlockwise?: boolean): void;
  ellipse(x: number, y: number, rx: number, ry: number, rotation: number, startAngle: number,
          endAngle: number, anticlockwise?: boolean): void;
  quadraticCurveTo(cx: number, cy: number, x: number, y: number): void;
  bezierCurveTo(c1x: number, c1y: number, c2x: number, c2y: number, x: number, y: number): void;
  fill(): void; stroke(): void; clip(rule?: "nonzero" | "evenodd"): void;
  fillText(text: string, x: number, y: number): void; strokeText(text: string, x: number, y: number): void;
  measureText(text: string): { width: number };
  createLinearGradient(x0: number, y0: number, x1: number, y1: number): CanvasGradient;
  createRadialGradient(x0: number, y0: number, r0: number, x1: number, y1: number, r1: number): CanvasGradient;
}
declare class CanvasGradient { addColorStop(offset: number, color: string): void; }

type Point = [number, number] | { x: number; y: number };
type GradientStops = string[] | { offset: number; color: string }[];   // offset 0–1; plain colours space evenly

declare class Group {
  readonly id: string;                      // "g12ab34"
  name: string;
  visible: boolean;
  opacity: number;
  blendMode: string | null;                 // null = pass through
  readonly parent: Group | null;
  readonly layers: Layer[];                 // direct members
  ungroup(): void;                          // dissolve, keeping the layers
  delete(): void;                           // delete the group AND its layers
}
"""#
}
