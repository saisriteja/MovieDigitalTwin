#!/usr/bin/env bash
# pinga_set: custom panorama → 3D mesh
# Stages 1 & 2 already done. Start from Stage 3.

set -euo pipefail

source /devwork/MiniConda/miniconda3/etc/profile.d/conda.sh
conda activate gsplat_env

export HF_HOME=/workspace/teja/models
export HF_HUB_CACHE=/workspace/teja/models/hub
export LD_LIBRARY_PATH="$CONDA_PREFIX/lib/python3.11/site-packages/nvidia/cu13/lib:$LD_LIBRARY_PATH"
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

export TARGET_PATH=/devwork/teja/HY-World-2.0/pinga_set
export RESULT_DIR=/devwork/teja/HY-World-2.0/pinga_set/gs_output

cd /devwork/teja/HY-World-2.0/hyworld2/worldgen

# ── Stage 3: WorldStereo (use GPU 1; make sure it is free) ──────────────────
CUDA_VISIBLE_DEVICES=1 torchrun --nproc_per_node 1 video_gen.py \
  --target_path "$TARGET_PATH" --fsdp

# Optional — better quality, slower:
# CUDA_VISIBLE_DEVICES=1 torchrun --nproc_per_node 1 video_gen.py \
#   --target_path "$TARGET_PATH" --model_type worldstereo-memory --fsdp

# ── Stage 4: Prepare 3DGS training data ─────────────────────────────────────
CUDA_VISIBLE_DEVICES=1 torchrun --nproc_per_node 1 gen_gs_data.py \
  --root_path "$TARGET_PATH" --save_normal --split_sky

# ── Stage 5: 3DGS training (~1-2 hrs on single GPU) ─────────────────────────
CUDA_VISIBLE_DEVICES=1 python -m world_gs_trainer default \
  --data_dir "$TARGET_PATH/gs_data" \
  --result_dir "$RESULT_DIR" \
  --max_steps 8000 --save_steps 8000 --eval_steps 8000 --ply_steps 8000 \
  --save_ply --convert_to_spz --disable_video \
  --use_scale_regularization --antialiased \
  --depth_loss --normal_loss --sky_depth_from_pcd \
  --use_mask_gaussian --mask_export_stochastic \
  --no-mask-export-anchor-protection --use_anchor_protection --export_mesh \
  --strategy.refine-start-iter 800 --strategy.refine-stop-iter 4000 \
  --strategy.refine-every 533 --strategy.refine-scale2d-stop-iter 4000 \
  --strategy.reset-every 99990 --strategy.grow-grad2d 0.0001 --strategy.prune-scale3d 0.1

# ── Stage 6: Extract final mesh ─────────────────────────────────────────────
python gs/extract_mesh.py \
  --ckpt "$RESULT_DIR/ckpts/ckpt_7999_rank0.pt" \
  --data_dir "$TARGET_PATH/gs_data"

# ── View result ───────────────────────────────────────────────────────────────
python show_gs.py --port 8081 --gpu_id 1 \
  --ckpt "$RESULT_DIR/ckpts/ckpt_7999_rank0.pt"

# Preview mesh (already available from Stage 1):
# /devwork/teja/HY-World-2.0/pinga_set/render_results/global_mesh.ply
