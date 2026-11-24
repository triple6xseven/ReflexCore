import { createReadStream, statSync } from 'node:fs';
import { createInterface } from 'node:readline';

const scenes = new Set(['menu', 'console', 'loading', 'match', 'dead', 'spectator', 'unknown', 'stale']);

function validBox(box) {
    return Array.isArray(box) && box.length === 4 &&
        box.every(Number.isFinite) && box[0] >= 0 && box[1] >= 0 && box[2] > 0 && box[3] > 0 &&
        box[0] + box[2] <= 16384 && box[1] + box[3] <= 16384;
}

function overlap(a, b) {
    const width = Math.max(0, Math.min(a[0] + a[2], b[0] + b[2]) - Math.max(a[0], b[0]));
    const height = Math.max(0, Math.min(a[1] + a[3], b[1] + b[3]) - Math.max(a[1], b[1]));
    const intersection = width * height;
    if (!intersection) return 0;
    return intersection / (a[2] * a[3] + b[2] * b[3] - intersection);
}

const file = process.argv[2];
if (!file) throw new Error('Usage: node tools/score-reflexvision.mjs <private-frame-records.jsonl>');

const input = statSync(file);
if (!input.isFile() || input.size > 128 * 1024 * 1024) throw new Error('Expected a frame-record file of at most 128 MiB');
const frames = new Set();
const age = [];
const sceneObserver = { frames: 0, correct: 0, falseMatch: 0, missedMatch: 0, unavailable: 0 };
let emptyMatchFrames = 0;
let synchronizedMatchFrames = 0;
const counts = { tp: 0, fp: 0, fn: 0, negativeFramesWithBoxes: 0, nonMatchFramesWithBoxes: 0, emptyMatchFramesWithBoxes: 0 };
const byScene = Object.fromEntries([...scenes].map(scene => [scene, 0]));
const lines = createInterface({ input: createReadStream(file, { encoding: 'utf8' }), crlfDelay: Infinity });
for await (const line of lines) {
    if (!line.trim()) continue;
    if (line.length > 65536 || frames.size >= 100000) throw new Error('Frame dataset exceeds limits');
    const record = JSON.parse(line);
    const { frame, tick, scene, truth, detections, observation_age_ms, source } = record;
    if (!Number.isSafeInteger(frame) || frame < 0 || frames.has(frame) ||
        !(source === undefined || source === 'annotated_clip') || !scenes.has(scene) || (observation_age_ms !== undefined &&
            (!Number.isFinite(observation_age_ms) || observation_age_ms < 0 || observation_age_ms > (record.scene_model ? 180000 : 60000))) || (scene === 'match' && !(source === 'annotated_clip' && tick === null) && (!Number.isSafeInteger(tick) || tick < 0)) ||
        !Array.isArray(truth) || truth.length > 256 || !truth.every(validBox) ||
        !Array.isArray(detections) || detections.length > 256 || !detections.every(item =>
            item && validBox(item.box) && Number.isFinite(item.score) && item.score >= 0 && item.score <= 1) ||
        (scene !== 'match' && truth.length !== 0)) {
        throw new Error('Invalid frame record or duplicate frame ID');
    }
    if (record.predicted_scene !== undefined) {
        const prediction = record.predicted_scene;
        if (!scenes.has(prediction) || prediction === 'stale' ||
            !['observed', 'timeout', 'encoding_error', 'invalid_response', 'service_error'].includes(record.observer_status) ||
            (record.observer_status !== 'observed' && prediction !== 'unknown')) {
            throw new Error('Invalid scene observer evidence');
        }
        sceneObserver.frames++;
        if (record.observer_status !== 'observed') sceneObserver.unavailable++;
        else if (prediction === scene) sceneObserver.correct++;
        if (prediction === 'match' && scene !== 'match') sceneObserver.falseMatch++;
        if (prediction !== 'match' && scene === 'match') sceneObserver.missedMatch++;
    }
    frames.add(frame);
    byScene[scene]++;
    if (observation_age_ms !== undefined) age.push(observation_age_ms);
    if (scene === 'match' && truth.length === 0) emptyMatchFrames++;
    if (scene === 'match' && Number.isSafeInteger(tick)) synchronizedMatchFrames++;
    if (truth.length === 0 && detections.length > 0) {
        counts.negativeFramesWithBoxes++;
        if (scene === 'match') counts.emptyMatchFramesWithBoxes++;
        else counts.nonMatchFramesWithBoxes++;
    }
    const unmatched = new Set(truth.keys());
    for (const { box } of detections.sort((a, b) => b.score - a.score)) {
        let best = -1;
        let bestOverlap = 0.5;
        for (const index of unmatched) {
            const score = overlap(box, truth[index]);
            if (score < bestOverlap) continue;
            bestOverlap = score;
            best = index;
        }
        if (best === -1) counts.fp++;
        else {
            unmatched.delete(best);
            counts.tp++;
        }
    }
    counts.fn += unmatched.size;
}
if (!frames.size) throw new Error('No annotated frames supplied');

const { tp, fp, fn } = counts;
const nonMatchFrames = frames.size - byScene.match;
const rate = (count, samples) => samples ? count / samples : null;
age.sort((a, b) => a - b);
const percentile = q => age.length ? age[Math.ceil(q * age.length) - 1] : null;
console.log(JSON.stringify({
    frames: frames.size, byScene, ...counts,
    ...(sceneObserver.frames ? { sceneObserver } : {}),
    nonMatchFrames, emptyMatchFrames, synchronizedMatchFrames,
    nonMatchFalsePositiveRate: rate(counts.nonMatchFramesWithBoxes, nonMatchFrames),
    emptyMatchFalsePositiveRate: rate(counts.emptyMatchFramesWithBoxes, emptyMatchFrames),
    observationAgeMs: { samples: age.length, p50: percentile(0.5), p95: percentile(0.95) },
    precision: tp + fp ? tp / (tp + fp) : null,
    recall: tp + fn ? tp / (tp + fn) : null
}, null, 2));
