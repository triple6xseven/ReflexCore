# Lumen avatar provenance

Lumen is a recolored adaptation of Victoria Rubin, pixiv Inc.'s β VRoid Studio AvatarSample_4. Victoria supplies the original 3D mesh, rig, expression morphs, clothing meshes and spring-bone data. ReflexCore gives the character silver-blue hair, a graphite-violet textile palette, nickel highlights and two thigh variants. The attached product reference supplied the quality target. No assets from it were used.

Pixiv's model-specific page identifies Victoria Rubin and dedicates the model to CC0 1.0. The VRM itself specifies CC0, use by everyone and commercial use allowed. The original source SHA-256 is `b1372131bdbf233f46320146d565f342a7e4f6f4b8f2aefb301f1a283ec07e1e`. [Pixiv model terms](https://vroid.pixiv.help/hc/ja/articles/360014900233) · [English terms](https://vroid.pixiv.help/hc/en-us/articles/360014900233) · [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) · [Pinned source mirror](https://github.com/madjin/vrm-samples/blob/e16eb187100149a315ad92c3c9968f1d5baa6c7d/vroid/beta/Victoria_Rubin.vrm).

The adaptation keeps the original meshes, UVs, skeleton, normal textures, blend shapes and hair spring data. The embedded material textures have a 1024-pixel maximum edge. The two avatar files differ chiefly in how the body texture covers the thighs and legs. Both preserve the same rig and outfit geometry. The pose and rendering support depend on the importing runtime.

| File | Bytes | SHA-256 |
|---|---:|---|
| Lumen-stockings.vrm | 7,950,372 | `c4d9f59ca5feb038711132a2bb7940ab208c0425171171ddf5e14b977e25b291` |
| Lumen-bare-legs.vrm | 7,911,836 | `4c0d3a3f869b5b7c554a1ca133fe7bc34361246bb8bb7700e099517d038e82e4` |

Build both files with Python 3, NumPy and Pillow. Use `python examples/build_companion_avatar.py --download --output export` to acquire the pinned input and write the two VRMs. The builder checks the source SHA-256 before processing. The dependencies are needed only to author or rebuild assets.
