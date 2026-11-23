using System;
using System.Collections.Generic;
using System.Drawing;

namespace ReflexCore.Vision
{
    internal struct Detection
    {
        internal string Kind;
        internal Rectangle Box;
        internal float Score;
        internal Detection(string kind, Rectangle box, float score) { Kind = kind; Box = box; Score = score; }
    }

    internal interface IDetector
    {
        void Detect(Surface image, List<Detection> output);
    }

    internal sealed class ColorRegions : IDetector
    {
        private byte[] mask = new byte[0];
        private int[] work = new int[0];

        public unsafe void Detect(Surface image, List<Detection> output)
        {
            output.Clear();
            int width = image.Width, height = image.Height;
            var pixels = (uint*)image.Pixels;
            int sampleWidth = width / 2, sampleHeight = height * 4 / 10;
            int size = sampleWidth * sampleHeight;
            if (mask.Length != size) { mask = new byte[size]; work = new int[size]; }
            for (int y = 0; y < sampleHeight; y++)
                for (int x = 0; x < sampleWidth; x++)
                {
                    uint rgb = pixels[(y * width + x) * 2];
                    int red = (int)((rgb >> 16) & 255), green = (int)((rgb >> 8) & 255), blue = (int)(rgb & 255);
                    mask[y * sampleWidth + x] = (byte)(red >= 115 && red - green >= 57 && red - blue >= 49 ? 1 : 0);
                }

            for (int i = 0; i < size && output.Count < 16; i++)
            {
                if (mask[i] == 0) continue;
                int left = i % sampleWidth, right = left, top = i / sampleWidth, bottom = top;
                int tail = 1;
                work[0] = i;
                mask[i] = 0;
                for (int head = 0; head < tail; head++)
                {
                    int index = work[head], x = index % sampleWidth, y = index / sampleWidth;
                    left = Math.Min(left, x); right = Math.Max(right, x);
                    top = Math.Min(top, y); bottom = Math.Max(bottom, y);
                    if (x > 0) Add(index - 1, ref tail);
                    if (x + 1 < sampleWidth) Add(index + 1, ref tail);
                    if (y > 0) Add(index - sampleWidth, ref tail);
                    if (y + 1 < sampleHeight) Add(index + sampleWidth, ref tail);
                }
                int w = right - left + 1, h = bottom - top + 1;
                if (tail < 12 || w < 3 || h < 3 || w > sampleWidth / 4 || h > sampleHeight / 3) continue;
                float fill = tail / (float)(w * h);
                if (fill >= .15f)
                    output.Add(new Detection("red_cue", new Rectangle(2 * left, 2 * top, 2 * w, 2 * h), Math.Min(.9f, .5f + fill * .4f)));
            }

            // GoldSrc's default gold HUD. A tight ROI and occupancy bounds reject uniform scenery.
            Hud(pixels, width, height, 1, 16, "hud_health", output);
            Hud(pixels, width, height, 19, 35, "hud_armor", output);
            Hud(pixels, width, height, 42, 59, "hud_clock", output);
            Hud(pixels, width, height, 67, 99, "hud_ammo", output);
        }

        private void Add(int index, ref int tail)
        {
            if (mask[index] == 0) return;
            mask[index] = 0;
            work[tail++] = index;
        }

        private static unsafe void Hud(uint* pixels, int width, int height, int from, int to, string kind, List<Detection> output)
        {
            int x0 = width * from / 100, x1 = width * to / 100, y0 = height * 93 / 100, y1 = height * 99 / 100;
            int left = x1, right = x0, top = y1, bottom = y0, count = 0, activeRows = 0;
            for (int y = y0; y < y1; y++)
            {
                int rowCount = 0;
                for (int x = x0; x < x1; x++)
                {
                    uint rgb = pixels[y * width + x];
                    int red = (int)((rgb >> 16) & 255), green = (int)((rgb >> 8) & 255), blue = (int)(rgb & 255);
                    if (red < 159 || green < 112 || red < green || red - green > 105 || green - blue < 69) continue;
                    left = Math.Min(left, x); right = Math.Max(right, x);
                    top = Math.Min(top, y); bottom = y;
                    rowCount++;
                }
                count += rowCount;
                if (rowCount > 1) activeRows++;
            }
            if (count < 10 || activeRows < 3 || right - left < 4 || count > (x1 - x0) * (y1 - y0) * .52) return;
            output.Add(new Detection(kind, Rectangle.FromLTRB(left, top, right + 1, bottom + 1), .65f));
        }
    }

    internal sealed class Track
    {
        internal int Id, Hits;
        internal bool Matched;
        internal long LastSeen;
        internal Detection Object;
    }

    internal sealed class Tracker
    {
        internal const int MaxAgeMs = 350;
        private int nextId;
        private readonly List<Track> tracks = new List<Track>(24);

        internal void Clear() { tracks.Clear(); }

        private static float Overlap(Rectangle a, Rectangle b)
        {
            Rectangle shared = Rectangle.Intersect(a, b);
            int area = shared.Width * shared.Height;
            return area == 0 ? 0 : area / (float)(a.Width * a.Height + b.Width * b.Height - area);
        }

        internal void Update(List<Detection> detections, long now, List<Track> confirmed)
        {
            tracks.RemoveAll(track => now - track.LastSeen > MaxAgeMs);
            foreach (var track in tracks) track.Matched = false;
            confirmed.Clear();
            foreach (var detection in detections)
            {
                Track nearest = null; float best = .18f;
                foreach (var track in tracks)
                {
                    if (track.Matched || track.Object.Kind != detection.Kind) continue;
                    float overlap = Overlap(track.Object.Box, detection.Box);
                    if (overlap > best) { nearest = track; best = overlap; }
                }
                if (nearest == null)
                {
                    if (tracks.Count >= 48) continue;
                    nearest = new Track { Id = ++nextId };
                    tracks.Add(nearest);
                }
                nearest.Object = detection;
                nearest.LastSeen = now;
                nearest.Matched = true;
                nearest.Hits = Math.Min(2, nearest.Hits + 1);
                if (nearest.Hits == 2) confirmed.Add(nearest);
            }
            // Tentative hits must be consecutive. Occluded confirmed tracks can reacquire their ID.
            tracks.RemoveAll(track => !track.Matched && track.Hits == 1);
        }
    }
}
