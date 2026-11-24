use serde::{Deserialize, Serialize};

#[derive(Serialize)]
pub(crate) struct ModelDescriptor {
    id: &'static str,
    kind: &'static str,
    interface: &'static str,
    inputs: &'static [&'static str],
    outputs: &'static [&'static str],
    runtime: &'static str,
    version_source: &'static str,
    artifact_license: &'static str,
    resource_control: &'static str,
}

pub(crate) const MODELS: &[ModelDescriptor] = &[
    ModelDescriptor {
        id: "vision.yolox_tiny",
        kind: "visual_object_detector",
        interface: "reflexvision worker protocol",
        inputs: &["bounded client frame"],
        outputs: &["person boxes", "confidence"],
        runtime: "ReflexVision OpenCV DNN CPU",
        version_source: "official ONNX artifact SHA-256 verified by worker",
        artifact_license: "verify the selected export against upstream release terms",
        resource_control: "two CPU threads; ends with preview worker; no GPU",
    },
    ModelDescriptor {
        id: "vision.ollama",
        kind: "vision_language_model",
        interface: "loopback /api/generate and /api/ps",
        inputs: &["bounded image", "prompt", "output schema"],
        outputs: &["validated response", "inference timings"],
        runtime: "existing Ollama inference and lease manager",
        version_source: "installed model manifest and digest",
        artifact_license: "per installed Ollama model",
        resource_control: "bounded options and keep-alive lease; residency reported by /api/ps",
    },
    ModelDescriptor {
        id: "motion.mlp",
        kind: "lightweight_movement_policy",
        interface: "motion checkpoint JSON format 1",
        inputs: &["remaining distance", "measured gain", "observation delay"],
        outputs: &["one of three pulse classes"],
        runtime: "native Rust CPU laboratory",
        version_source: "checkpoint SHA-256",
        artifact_license: "locally generated from synthetic trajectories",
        resource_control:
            "87 parameters; a separate CPU training invocation; no active core weights",
    },
];

pub(crate) const PULSES: [f32; 3] = [0.18, 0.43, 0.83];
const WIDTH: usize = 12;

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Model {
    input: [[f32; 3]; WIDTH],
    hidden_bias: [f32; WIDTH],
    output: [[f32; WIDTH]; 3],
    output_bias: [f32; 3],
}

impl Model {
    pub(crate) fn seeded(random: &mut impl FnMut() -> f32) -> Self {
        Self {
            input: std::array::from_fn(|_| std::array::from_fn(|_| (random() - 0.5) * 1.2)),
            hidden_bias: [0.0; WIDTH],
            output: std::array::from_fn(|_| std::array::from_fn(|_| (random() - 0.5) * 0.7)),
            output_bias: [0.0; 3],
        }
    }

    fn forward(&self, x: [f32; 3]) -> ([f32; WIDTH], [f32; 3]) {
        let h = std::array::from_fn(|i| {
            (self.hidden_bias[i] + self.input[i].iter().zip(x).map(|(w, a)| w * a).sum::<f32>())
                .tanh()
        });
        let y = std::array::from_fn(|i| {
            self.output_bias[i]
                + self.output[i]
                    .iter()
                    .zip(h)
                    .map(|(w, a)| w * a)
                    .sum::<f32>()
        });
        (h, y)
    }

    pub(crate) fn choose(&self, x: [f32; 3]) -> usize {
        let (_, y) = self.forward(x);
        (0..3).max_by(|&a, &b| y[a].total_cmp(&y[b])).unwrap_or(1)
    }

    pub(crate) fn train_batch(&mut self, batch: &[([f32; 3], usize)]) {
        let mut d_input = [[0.0; 3]; WIDTH];
        let mut d_hidden_bias = [0.0; WIDTH];
        let mut d_output = [[0.0; WIDTH]; 3];
        let mut d_output_bias = [0.0; 3];
        for &(x, desired) in batch {
            let (h, y) = self.forward(x);
            let high = y.into_iter().fold(f32::NEG_INFINITY, f32::max);
            let exp = y.map(|value| (value - high).exp());
            let denominator = exp.iter().sum::<f32>();
            let error: [f32; 3] = std::array::from_fn(|i| {
                exp[i] / denominator - if i == desired { 1.0 } else { 0.0 }
            });
            for (i, e) in error.into_iter().enumerate() {
                d_output_bias[i] += e;
                for (gradient, activation) in d_output[i].iter_mut().zip(h) {
                    *gradient += e * activation;
                }
            }
            for j in 0..WIDTH {
                let e =
                    (1.0 - h[j] * h[j]) * (0..3).map(|i| self.output[i][j] * error[i]).sum::<f32>();
                d_hidden_bias[j] += e;
                for (gradient, feature) in d_input[j].iter_mut().zip(x) {
                    *gradient += e * feature;
                }
            }
        }
        let rate = 0.13 / batch.len() as f32;
        for (weights, gradient) in self.input.iter_mut().zip(d_input) {
            for (weight, delta) in weights.iter_mut().zip(gradient) {
                *weight -= rate * delta;
            }
        }
        for (bias, delta) in self.hidden_bias.iter_mut().zip(d_hidden_bias) {
            *bias -= rate * delta;
        }
        for (weights, gradient) in self.output.iter_mut().zip(d_output) {
            for (weight, delta) in weights.iter_mut().zip(gradient) {
                *weight -= rate * delta;
            }
        }
        for (bias, delta) in self.output_bias.iter_mut().zip(d_output_bias) {
            *bias -= rate * delta;
        }
    }
}
