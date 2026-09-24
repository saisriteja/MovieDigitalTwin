#!/usr/bin/env bash
# HY-World 2.0: Custom panorama → 3D mesh pipeline for pinga_set
# Usage: bash run_mesh_pipeline.sh [stage]
#   stage: all | setup | vllm | traj | render | video | gsdata | train | mesh
set -euo pipefail

STAGE="${1:-all}"
TARGET_PATH="/devwork/teja/HY-World-2.0/pinga_set"
RESULT_DIR="${TARGET_PATH}/gs_output"
LLM_ADDR="localhost"
LLM_PORT=8000
LLM_NAME="Qwen/Qwen3-VL-8B-Instruct"

source /devwork/MiniConda/miniconda3/etc/profile.d/conda.sh
conda activate gsplat_env
export HF_HOME="${HF_HOME:-/workspace/teja/models}"
export HF_HUB_CACHE="${HF_HUB_CACHE:-/workspace/teja/models/hub}"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
export LD_LIBRARY_PATH="${CONDA_PREFIX}/lib/python3.11/site-packages/nvidia/cu13/lib:${LD_LIBRARY_PATH:-}"
cd /devwork/teja/HY-World-2.0/hyworld2/worldgen

run_setup() {
  cp -n "${TARGET_PATH}/ping_set.png" "${TARGET_PATH}/panorama.png" 2>/dev/null || true
  if [ ! -f "${TARGET_PATH}/meta_info.json" ]; then
    echo '{"scene_type": "outdoor"}' > "${TARGET_PATH}/meta_info.json"
  fi
  echo "Scene ready at ${TARGET_PATH}"
}

run_vllm() {
  echo "Starting vLLM on GPU 1 (port ${LLM_PORT})..."
  CUDA_VISIBLE_DEVICES=1 vllm serve "${LLM_NAME}" \
    --served-model-name "${LLM_NAME}" \
    --port "${LLM_PORT}" --host 0.0.0.0 \
    --tensor-parallel-size 1 \
    --max-model-len 16384 \
    --trust-remote-code \
    --gpu-memory-utilization 0.30
}

run_traj() {
  echo "=== Stage 1: Trajectory planning + depth/mesh from panorama ==="
  CUDA_VISIBLE_DEVICES=0 python traj_generate.py \
    --target_path "${TARGET_PATH}" \
    --llm_addr "${LLM_ADDR}" --llm_port "${LLM_PORT}" --llm_name "${LLM_NAME}" \
    --apply_nav_traj --apply_up_route --apply_recon_iteration --force_vlm
}

run_render() {
  echo "=== Stage 2: Trajectory rendering ==="
  CUDA_VISIBLE_DEVICES=0 torchrun --nproc_per_node 1 traj_render.py \
    --target_path "${TARGET_PATH}" \
    --llm_addr "${LLM_ADDR}" --llm_port "${LLM_PORT}" --llm_name "${LLM_NAME}"
}

run_video() {
  echo "=== Stage 3: WorldStereo world expansion (use GPU 1 to avoid OOM on GPU 0) ==="
  CUDA_VISIBLE_DEVICES=1 torchrun --nproc_per_node 1 video_gen.py \
    --target_path "${TARGET_PATH}" --fsdp
}

run_gsdata() {
  echo "=== Stage 4: GS training data prep ==="
  CUDA_VISIBLE_DEVICES=0 torchrun --nproc_per_node 1 gen_gs_data.py \
    --root_path "${TARGET_PATH}" --save_normal --split_sky
}

run_train() {
  echo "=== Stage 5: 3DGS training (single GPU, 8000 steps) ==="
  CUDA_VISIBLE_DEVICES=0 python -m world_gs_trainer default \
    --data_dir "${TARGET_PATH}/gs_data" \
    --result_dir "${RESULT_DIR}" \
    --max_steps 8000 --save_steps 8000 --eval_steps 8000 --ply_steps 8000 \
    --save_ply --convert_to_spz --disable_video \
    --use_scale_regularization --antialiased \
    --depth_loss --normal_loss --sky_depth_from_pcd \
    --use_mask_gaussian --mask_export_stochastic \
    --no-mask-export-anchor-protection --use_anchor_protection --export_mesh \
    --strategy.refine-start-iter 800 --strategy.refine-stop-iter 4000 \
    --strategy.refine-every 533 --strategy.refine-scale2d-stop-iter 4000 \
    --strategy.reset-every 99990 --strategy.grow-grad2d 0.0001 --strategy.prune-scale3d 0.1
}

run_mesh() {
  echo "=== Stage 6: Extract final mesh ==="
  python gs/extract_mesh.py \
    --ckpt "${RESULT_DIR}/ckpts/ckpt_7999_rank0.pt" \
    --data_dir "${TARGET_PATH}/gs_data"
  echo "Mesh outputs in: ${RESULT_DIR}/mesh/"
}

case "${STAGE}" in
  setup)   run_setup ;;
  vllm)    run_vllm ;;
  traj)    run_traj ;;
  render)  run_render ;;
  video)   run_video ;;
  gsdata)  run_gsdata ;;
  train)   run_train ;;
  mesh)    run_mesh ;;
  all)
    run_setup
    echo "NOTE: Start vLLM in a separate terminal first:"
    echo "  bash ${TARGET_PATH}/run_mesh_pipeline.sh vllm"
    echo "Then run stages individually: traj → render → video → gsdata → train → mesh"
    ;;
  *)
    echo "Unknown stage: ${STAGE}"
    echo "Valid: setup | vllm | traj | render | video | gsdata | train | mesh | all"
    exit 1
    ;;
esac
