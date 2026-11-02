// 文件四角偵測與透視校正（OpenCV.js）
// 移植自同一作者的 Photo to PDF 專案（src/scanner.js），演算法相同
// 演算法參考 jscanify：邊緣偵測 → 找最大的四邊形輪廓 → 透視轉換

// 用 <script> 載入而不是 import：打包工具會把 OpenCV 的 Promise 包成假的 Promise，await 時會出錯
import opencvUrl from "@techstark/opencv-js/dist/opencv.js?url";

let cvPromise = null;

// OpenCV.js 約 13MB，第一次用到時才載入
export function loadOpenCv() {
  cvPromise ??= new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = opencvUrl;
    script.onload = resolve;
    script.onerror = () => {
      cvPromise = null; // 下次再試
      reject(new Error("影像處理模組載入失敗，請確認網路後再試一次。"));
    };
    document.head.append(script);
  }).then(async () => {
    const cv = window.cv;
    if (cv instanceof Promise) return await cv;
    if (cv.Mat) return cv;
    await new Promise((resolve) => {
      cv.onRuntimeInitialized = resolve;
    });
    return cv;
  });
  return cvPromise;
}

// 偵測時先縮小，速度快很多，結果再放大回原尺寸
const DETECT_SIDE = 500;

// 回傳 [左上, 右上, 右下, 左下]，座標為原圖像素；找不到文件時回傳整張圖的四角
export async function detectCorners(canvas) {
  const cv = await loadOpenCv();
  const scale = Math.min(
    1,
    DETECT_SIDE / Math.max(canvas.width, canvas.height),
  );

  const src = cv.imread(canvas);
  const small = new cv.Mat();
  cv.resize(src, small, new cv.Size(0, 0), scale, scale, cv.INTER_AREA);
  src.delete();

  const gray = new cv.Mat();
  cv.cvtColor(small, gray, cv.COLOR_RGBA2GRAY);
  cv.GaussianBlur(gray, gray, new cv.Size(5, 5), 0);

  const imageArea = small.rows * small.cols;
  const minArea = imageArea * 0.1; // 至少佔畫面 10% 才算文件
  let best = null;
  let bestScore = 0;
  for (const mask of edgeMasks(cv, gray)) {
    const contours = new cv.MatVector();
    const hierarchy = new cv.Mat();
    // RETR_LIST：連內層輪廓也看，文件邊框常被外圍雜線包住
    cv.findContours(
      mask,
      contours,
      hierarchy,
      cv.RETR_LIST,
      cv.CHAIN_APPROX_SIMPLE,
    );
    for (let i = 0; i < contours.size(); i++) {
      const contour = contours.get(i);
      const area = cv.contourArea(contour);
      // 太接近整張圖的通常是照片邊界，不是文件
      if (area > minArea && area < imageArea * 0.97) {
        const quad = toQuad(cv, contour, area);
        if (quad) {
          // 四邊形比實際輪廓多出越多空白，分數扣越重：避免文件和旁邊雜物連成一塊時被選中
          const fill = Math.min(1, area / polygonArea(quad));
          const score = area * fill ** 4;
          if (score > bestScore) {
            bestScore = score;
            best = quad;
          }
        }
      }
      contour.delete();
    }
    contours.delete();
    hierarchy.delete();
    mask.delete();
  }
  [small, gray].forEach((m) => m.delete());

  if (!best) return fullImageCorners(canvas);
  return orderCorners(best.map((p) => ({ x: p.x / scale, y: p.y / scale })));
}

// 產生幾種候選的二值圖：邊緣偵測 + 亮度分割（紙通常比背景亮）
function edgeMasks(cv, gray) {
  const kernel = cv.Mat.ones(3, 3, cv.CV_8U);
  const masks = [];
  for (const [low, high] of [
    [50, 150],
    [25, 80],
  ]) {
    const edges = new cv.Mat();
    cv.Canny(gray, edges, low, high);
    cv.dilate(edges, edges, kernel);
    masks.push(edges);
  }
  const bright = new cv.Mat();
  cv.threshold(gray, bright, 0, 255, cv.THRESH_BINARY | cv.THRESH_OTSU);
  cv.morphologyEx(bright, bright, cv.MORPH_OPEN, kernel);
  masks.push(bright);
  kernel.delete();
  return masks;
}

// 把輪廓簡化成四邊形；不是四邊形就回傳 null
function toQuad(cv, contour, area) {
  let quad = approxQuad(cv, contour);
  if (!quad) {
    // 邊緣有缺口或雜點時改用凸包，但輪廓必須夠「實心」，避免把文件和桌緣連成一大塊
    const hull = new cv.Mat();
    cv.convexHull(contour, hull);
    if (area / cv.contourArea(hull) > 0.9) quad = approxQuad(cv, hull);
    hull.delete();
  }
  return quad;
}

function approxQuad(cv, curve) {
  const perimeter = cv.arcLength(curve, true);
  for (const ratio of [0.02, 0.03, 0.05]) {
    const approx = new cv.Mat();
    cv.approxPolyDP(curve, approx, ratio * perimeter, true);
    const rows = approx.rows;
    let quad = null;
    if (rows === 4 && cv.isContourConvex(approx)) {
      const d = approx.data32S;
      quad = [0, 2, 4, 6].map((j) => ({ x: d[j], y: d[j + 1] }));
    }
    approx.delete();
    if (quad) return quad;
    if (rows < 4) return null;
  }
  return null;
}

export function fullImageCorners(canvas) {
  const w = canvas.width;
  const h = canvas.height;
  return [
    { x: 0, y: 0 },
    { x: w, y: 0 },
    { x: w, y: h },
    { x: 0, y: h },
  ];
}

// 依「x+y 最小 = 左上、最大 = 右下；y-x 最小 = 右上、最大 = 左下」排序
function orderCorners(points) {
  const bySum = [...points].sort((a, b) => a.x + a.y - (b.x + b.y));
  const byDiff = [...points].sort((a, b) => a.y - a.x - (b.y - b.x));
  return [bySum[0], byDiff[0], bySum[3], byDiff[3]];
}

function polygonArea(points) {
  let sum = 0;
  points.forEach((p, i) => {
    const q = points[(i + 1) % points.length];
    sum += p.x * q.y - q.x * p.y;
  });
  return Math.abs(sum) / 2;
}

const dist = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);

// 依四角把文件拉成正面的長方形，回傳新 canvas
export async function warp(canvas, corners) {
  const cv = await loadOpenCv();
  const [tl, tr, br, bl] = corners;
  const w = Math.round(Math.max(dist(tl, tr), dist(bl, br)));
  const h = Math.round(Math.max(dist(tl, bl), dist(tr, br)));

  const src = cv.imread(canvas);
  const from = cv.matFromArray(
    4,
    1,
    cv.CV_32FC2,
    corners.flatMap((p) => [p.x, p.y]),
  );
  const to = cv.matFromArray(4, 1, cv.CV_32FC2, [0, 0, w, 0, w, h, 0, h]);
  const matrix = cv.getPerspectiveTransform(from, to);
  const dst = new cv.Mat();
  cv.warpPerspective(
    src,
    dst,
    matrix,
    new cv.Size(w, h),
    cv.INTER_LINEAR,
    cv.BORDER_REPLICATE,
  );

  const out = document.createElement("canvas");
  cv.imshow(out, dst);
  [src, from, to, matrix, dst].forEach((m) => m.delete());
  return out;
}
