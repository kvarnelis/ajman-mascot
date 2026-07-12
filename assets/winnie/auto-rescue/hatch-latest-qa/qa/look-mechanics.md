# Winnie look mechanics

Winnie looks around like a real alert cat. Her paws and lower torso remain planted at one stable baseline. Her yellow-green eyes lead each gaze, then her narrow head turns or pitches, with the large ears following and independently aiming toward the target. Her shoulders follow only slightly; her pink collar and centered round tag remain attached and lag by a very small natural amount. Her tail stays readable and may counterbalance subtly without jumping sides.

Motion budget: each 22.5-degree step moves the pupils, nose, head angle, ear aim, and upper chest by a comparable small amount. Preserve head size, body scale, stripe identity, collar placement, and baseline. Do not rotate or tilt the whole sprite.

- 000 up: chin lifts, pupils and nose aim upward, more underside of muzzle is visible, ears stand tall and aim up; body remains front-facing.
- 090 screen-right: Winnie turns her face toward the image's right edge; nose and pupils sit right of head center, left cheek becomes more visible, right cheek partly occludes; ears yaw with the head.
- 180 down: chin tucks toward chest, pupils aim down, forehead and ear tops become more visible, muzzle is partly occluded; paws stay fixed.
- 270 screen-left: Winnie turns her face toward the image's left edge; nose and pupils sit left of head center, right cheek becomes more visible, left cheek partly occludes; ears yaw with the head.

Diagonals interpolate evenly between those four families. Eye movement is combined with eyelid shape, head turn/pitch, ear follow-through, and restrained shoulder follow-through; pupil-only motion is not sufficient. The collar and tag follow the neck continuously and never detach or flip.
