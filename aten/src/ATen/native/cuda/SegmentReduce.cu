#define TORCH_ASSERT_ONLY_METHOD_OPERATORS
#include <ATen/native/SegmentReduce.h>

#include <ATen/core/Tensor.h>
#include <ATen/Dispatch.h>
#include <ATen/NumericUtils.h>
#include <ATen/cuda/CUDAContext.h>
#include <ATen/cuda/detail/KernelUtils.h>
#include <ATen/cuda/cub.cuh>

#ifndef AT_PER_OPERATOR_HEADERS
#include <ATen/Functions.h>
#else
#include <ATen/ops/empty.h>
#include <ATen/ops/zeros.h>
#include <ATen/ops/cat.h>
#include <ATen/ops/cumsum.h>
#endif

namespace at {
namespace native {

namespace {
struct CustomMax {
  template <typename OutputT>
  __host__ __device__ __forceinline__ OutputT
  operator()(const OutputT& a, const OutputT& b) const {
    if (at::_isnan(a)) {
      return a;
    } else if (at::_isnan(b)) {
      return b;
    }
    return std::max<OutputT>(a, b);
  }
};

struct CustomSum {
  template <typename OutputT>
  __host__ __device__ __forceinline__ OutputT
  operator()(const OutputT& a, const OutputT& b) const {
    return a + b;
  }
};

struct CustomProd {
  template <typename OutputT>
  __host__ __device__ __forceinline__ OutputT
  operator()(const OutputT& a, const OutputT& b) const {
    return a * b;
  }
};

struct CustomMin {
  template <typename OutputT>
  __host__ __device__ __forceinline__ OutputT
  operator()(const OutputT& a, const OutputT& b) const {
    if (at::_isnan(a)) {
      return a;
    } else if (at::_isnan(b)) {
      return b;
    }
    return std::min<OutputT>(a, b);
  }
};

Tensor _get_complete_sum(const Tensor& lengths) {
  int64_t segment_count = lengths.numel();
  TORCH_CHECK(segment_count < INT_MAX);
  auto offsets = at::empty({segment_count + 1}, lengths.options());
  offsets[0].zero_();

  AT_DISPATCH_INDEX_TYPES(
      lengths.scalar_type(), "_segment_reduce_cuda_backward_kernel1", ([&] {
        auto* lengths_data_ptr = lengths.data_ptr<index_t>();
        auto* offsets_data_ptr = offsets.data_ptr<index_t>();
        at::cuda::cub::inclusive_sum(
            lengths_data_ptr,
            offsets_data_ptr + 1,
            segment_count);
      }));
  return offsets;
}

template <typename scalar_t, typename index_t>
__global__ static void post_sum_div_kernel(
    scalar_t* output_data,
    const index_t* lengths_data,
    const int64_t segment_count,
    bool is_initial_set,
    scalar_t initial) {
  CUDA_KERNEL_LOOP(index, segment_count) {
    CUDA_KERNEL_ASSERT(lengths_data[index] >= 0);
    if (lengths_data[index] == 0) {
      if (is_initial_set) {
        output_data[index] = initial;
      } else {
        output_data[index] = NAN;
      }
    } else if (!at::_isnan(output_data[index])) {
      output_data[index] = output_data[index] / lengths_data[index];
    }
  }
}

template <typename scalar_t, typename index_t>
__global__ void segment_reduce_forward_kernel(
    SegmentReductionType reduction,
    scalar_t* output_data,
    scalar_t* values_data,
    const index_t* lengths_data,
    const index_t* lengths_cumsum_data,
    const int64_t segment_count,
    const int64_t lengths_stride_axis,
    bool is_initial_set,
    scalar_t initial_value,
    const int64_t outer_offset,
    const int64_t inner_offset,
    const int64_t data_stride_axis,
    const int64_t data_size_axis,
    const int64_t output_stride_axis,
    const int64_t output_size_axis,
    const int64_t lengths_cumsum_stride_axis) {
  int64_t idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx >= (outer_offset * segment_count * inner_offset)) {
    return;
  }
  int64_t row_id = idx / inner_offset;
  int64_t lane_id = idx % inner_offset;   // lane_id is the inner_idx
  int64_t outer_idx = row_id / segment_count;
  int64_t dim_idx = row_id % segment_count;

  int64_t offset_idx = outer_idx * lengths_cumsum_stride_axis * (segment_count + 1) + dim_idx;
  index_t offset_start = lengths_cumsum_data[offset_idx];
  index_t offset_end = lengths_cumsum_data[offset_idx + 1];

  // ===== step2: apply reduction
  for (index_t j = offset_start; j < offset_end; ++j) {
    int64_t data_index = outer_idx * data_stride_axis * data_size_axis
                         + j * data_stride_axis + lane_id;
    const auto data = values_data[data_index];
    // TODO: There is no need to branch with every element
    if (reduction == SegmentReductionType::MAX) {
      initial_value =
          at::_isnan(data) ? data : std::max<scalar_t>(initial_value, data);
    } else if (
        reduction == SegmentReductionType::MEAN ||
        reduction == SegmentReductionType::SUM) {
      initial_value = initial_value + data;
    } else if (reduction == SegmentReductionType::MIN) {
      initial_value =
          at::_isnan(data) ? data : std::min<scalar_t>(initial_value, data);
    } else if (
      reduction == SegmentReductionType::PROD) {
      initial_value = initial_value * data;
    }
  }

  // ===== step3: finalize reduction
  int64_t lengths_idx = outer_idx * lengths_stride_axis * segment_count + dim_idx;
  CUDA_KERNEL_ASSERT(lengths_data[lengths_idx] >= 0);
  if (lengths_data[lengths_idx] == 0 && !is_initial_set &&
      reduction == SegmentReductionType::MEAN) {
    initial_value = static_cast<scalar_t>(NAN);
  } else if (
      reduction == SegmentReductionType::MEAN && lengths_data[lengths_idx] > 0 &&
      !at::_isnan(initial_value)) {
    initial_value = initial_value / lengths_data[lengths_idx];
  }
  int64_t output_index = outer_idx * output_stride_axis * output_size_axis
                         + dim_idx * output_stride_axis + lane_id;
  output_data[output_index] = initial_value;
}


template <typename scalar_t, typename index_t>
__global__ void segment_reduce_backward_kernel(
    SegmentReductionType reduction,
    scalar_t* grad_input_data,
    scalar_t* grad_data,
    scalar_t* output_data,
    const scalar_t* values_data,
    const index_t* lengths_data,
    const index_t* lengths_cumsum_data,
    const int64_t segment_count,
    const int64_t lengths_stride_axis,
    scalar_t initial_prod_value,
    const int64_t outer_offset,
    const int64_t inner_offset,
    const int64_t data_stride_axis,
    const int64_t data_size_axis,
    const int64_t output_stride_axis,
    const int64_t output_size_axis,
    const int64_t lengths_cumsum_stride_axis) {
  int64_t idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx >= (outer_offset * segment_count * inner_offset)) {
    return;
  }
  int64_t row_id = idx / inner_offset;
  int64_t lane_id = idx % inner_offset;  // lane_id is the inner_idx
  int64_t outer_idx = row_id / segment_count;
  int64_t dim_idx = row_id % segment_count;

  int64_t lengths_idx = outer_idx * lengths_stride_axis * segment_count + dim_idx;
  auto segment_length = lengths_data[lengths_idx];
  if (segment_length == 0) {
    return;
  }

  int64_t offset_idx = outer_idx * lengths_cumsum_stride_axis * (segment_count + 1) + dim_idx;
  index_t offset_start = lengths_cumsum_data[offset_idx];
  index_t offset_end = lengths_cumsum_data[offset_idx + 1];

  int64_t output_index = outer_idx * output_stride_axis * output_size_axis
                         + dim_idx * output_stride_axis + lane_id;

  if (reduction == SegmentReductionType::MAX ||
      reduction == SegmentReductionType::MIN) {
    int64_t counter = 0;
    for (int64_t j = offset_start; j < offset_end; ++j) {
      int64_t data_index = outer_idx * data_stride_axis * data_size_axis
                           + j * data_stride_axis + lane_id;
      if (at::_isnan(values_data[data_index]) ||
          values_data[data_index] == output_data[output_index]) {
        grad_input_data[data_index] = grad_data[output_index];
        counter++;
      }
    }
    // Average gradient based on number of maximum elements in the
    // segment
    if (counter < 2) {
      return;
    }
    for (int64_t j = offset_start; j < offset_end; ++j) {
      int64_t data_index = outer_idx * data_stride_axis * data_size_axis
                           + j * data_stride_axis + lane_id;
      if (grad_input_data[data_index] > 0) {
        grad_input_data[data_index] =
            grad_input_data[data_index] / counter;
      }
    }
  } else if (reduction == SegmentReductionType::MEAN) {
    auto grad_val = grad_data[output_index] / segment_length;
    for (int64_t j = offset_start; j < offset_end; ++j) {
      int64_t data_index = outer_idx * data_stride_axis * data_size_axis
                           + j * data_stride_axis + lane_id;
      grad_input_data[data_index] = grad_val;
    }
  } else if (reduction == SegmentReductionType::SUM) {
    const auto& grad_val = grad_data[output_index];
    for (int64_t j = offset_start; j < offset_end; ++j) {
      int64_t data_index = outer_idx * data_stride_axis * data_size_axis
                           + j * data_stride_axis + lane_id;
      grad_input_data[data_index] = grad_val;
    }
  } else if (reduction == SegmentReductionType::PROD) {
    const auto& grad_val = grad_data[output_index] * output_data[output_index];
    for (int64_t j = offset_start; j < offset_end; ++j) {
      int64_t data_index = outer_idx * data_stride_axis * data_size_axis
                           + j * data_stride_axis + lane_id;
      if (at::_isnan(values_data[data_index]) ||
          values_data[data_index] == 0) {
        // explicitly compute exclusive prod
        scalar_t exclusive_prod = initial_prod_value;
        int64_t prod_idx;
        for (int64_t k = offset_start; k < offset_end; ++k) {
          if (k != j) {
            prod_idx = outer_idx * data_stride_axis * data_size_axis
                       + k * data_stride_axis + lane_id;
            exclusive_prod *= values_data[prod_idx];
          }
        }
        grad_input_data[data_index] = grad_data[output_index] * exclusive_prod;
      } else {
        grad_input_data[data_index] = grad_val / values_data[data_index];
      }
    }
  }
}
} // namespace

Tensor _segment_reduce_cuda_backward_kernel(
    const Tensor& grad_contig,
    const Tensor& output_contig,
    const Tensor& data_contig,
    SegmentReductionType reduction,
    const Tensor& lengths_contig,
    int64_t axis,
    const c10::optional<Scalar>& initial) {
  axis = lengths_contig.dim() - 1;
  int64_t segment_count = lengths_contig.size(axis);
  int64_t lengths_stride_axis = lengths_contig.stride(axis);
  auto grad_input = at::zeros({data_contig.sizes()}, grad_contig.options());

  auto zeros_shape = lengths_contig.sizes().vec();
  zeros_shape[axis] = 1;
  auto offsets = at::cat({at::zeros(zeros_shape, lengths_contig.options()), lengths_contig}, axis);
  offsets.cumsum_(axis);

  // outer_offset is the size of the outer dimensions of output (before axis)
  // inner_offset is the size of the inner dimensions of output (after axis)
  int64_t outer_offset = 1, inner_offset = 1;
  for (int64_t d = 0; d < axis; d++) {
    outer_offset *= output_contig.size(d);
  }
  for (int64_t d = axis + 1; d < output_contig.dim(); d++) {
    inner_offset *= output_contig.size(d);
  }

  constexpr int threads_per_block = 256;
  int64_t num_blocks = (outer_offset * inner_offset * segment_count + threads_per_block - 1) / threads_per_block;

  num_blocks = std::max(num_blocks, (int64_t)1);

  auto data_stride_axis = data_contig.stride(axis);
  auto data_size_axis = data_contig.size(axis);
  auto output_stride_axis = output_contig.stride(axis);
  auto output_size_axis = output_contig.size(axis);
  auto offsets_stride_axis = offsets.stride(axis);

  AT_DISPATCH_INDEX_TYPES(
      lengths_contig.scalar_type(), "_segment_reduce_cuda_backward_kernel1", ([&] {
        const auto* lengths_data = lengths_contig.data_ptr<index_t>();
        auto* offsets_data = offsets.data_ptr<index_t>();

        // TODO: Switch to TensorIterator for better maintainablility and
        // readability
        AT_DISPATCH_FLOATING_TYPES_AND2(
            kBFloat16,
            kHalf,
            data_contig.scalar_type(),
            "_segment_reduce_cpu",
            ([&]() {
              auto* output_data = output_contig.data_ptr<scalar_t>();
              auto* grad_data = grad_contig.data_ptr<scalar_t>();
              auto* grad_input_data = grad_input.data_ptr<scalar_t>();
              const auto* values_data = data_contig.data_ptr<scalar_t>();

              scalar_t initial_prod_value;
              if (initial.has_value()) {
                initial_prod_value = initial.value().to<scalar_t>();
              } else {
                initial_prod_value = 1;
              }

              segment_reduce_backward_kernel<scalar_t>
                  <<<num_blocks,
                     threads_per_block,
                     0,
                     at::cuda::getCurrentCUDAStream()>>>(
                      reduction,
                      grad_input_data,
                      grad_data,
                      output_data,
                      values_data,
                      lengths_data,
                      offsets_data,
                      segment_count,
                      lengths_stride_axis,
                      initial_prod_value,
                      outer_offset,
                      inner_offset,
                      data_stride_axis,
                      data_size_axis,
                      output_stride_axis,
                      output_size_axis,
                      offsets_stride_axis
                    );
              C10_CUDA_KERNEL_LAUNCH_CHECK();
            }));
      }));
  return grad_input;
}

Tensor _segment_reduce_cuda_kernel(
    SegmentReductionType reduction,
    const Tensor& data,
    const Tensor& lengths,
    int64_t axis,
    const c10::optional<Scalar>& initial) {
  // data and lengths should be contiguous from the call to .contiguous in segment_reduce_kernel
  TORCH_CHECK(data.is_contiguous(), "Expected data to be contiguous.");
  TORCH_CHECK(lengths.is_contiguous(), "Expected lengths to be contiguous.");
  axis = lengths.dim() - 1;
  int64_t segment_count = lengths.size(axis);
  int64_t lengths_stride_axis = lengths.stride(axis);
  auto output_shape = data.sizes().vec();
  output_shape[axis] = segment_count;
  auto output = at::empty(output_shape, data.options());

  // _get_complete_sum only supports 1D?
  auto zeros_shape = lengths.sizes().vec();
  zeros_shape[axis] = 1;
  auto offsets = at::cat({at::zeros(zeros_shape, lengths.options()), lengths}, axis);
  offsets.cumsum_(axis);

  // outer_offset is the size of the outer dimensions of output (before axis)
  // inner_offset is the size of the inner dimensions of output (after axis)
  int64_t outer_offset = 1, inner_offset = 1;
  for (int64_t d = 0; d < axis; d++) {
    outer_offset *= output.size(d);
  }
  for (int64_t d = axis + 1; d < output.dim(); d++) {
    inner_offset *= output.size(d);
  }

  constexpr int threads_per_block = 256;
  // segment_count * stride_count is just output.numel() ?
  int64_t num_blocks = (output.numel() + threads_per_block - 1) / threads_per_block;

  num_blocks = std::max(num_blocks, (int64_t)1);

  auto data_stride_axis = data.stride(axis);
  auto data_size_axis = data.size(axis);
  auto output_stride_axis = output.stride(axis);
  auto output_size_axis = output.size(axis);
  auto offsets_stride_axis = offsets.stride(axis);

  AT_DISPATCH_INDEX_TYPES(
      lengths.scalar_type(), "_segment_reduce_cuda_kernel1", ([&] {
        auto* offsets_data_ptr = offsets.data_ptr<index_t>();
        auto* lengths_data_ptr = lengths.data_ptr<index_t>();
        AT_DISPATCH_FLOATING_TYPES_AND2(
            at::ScalarType::Half,
            at::ScalarType::BFloat16,
            data.scalar_type(),
            "segment_reduce_cuda",
            [&]() {
              auto* data_data_ptr = data.data_ptr<scalar_t>();
              auto* output_data_ptr = output.data_ptr<scalar_t>();

              // initialize starting value
              scalar_t initial_value;
              if (initial.has_value()) {
                initial_value = initial.value().to<scalar_t>();
              } else if (reduction == SegmentReductionType::MAX) {
                initial_value = -std::numeric_limits<scalar_t>::infinity();
              } else if (
                  reduction == SegmentReductionType::MEAN ||
                  reduction == SegmentReductionType::SUM) {
                initial_value = 0;
              } else if (reduction == SegmentReductionType::MIN) {
                initial_value = std::numeric_limits<scalar_t>::infinity();
              } else if (reduction == SegmentReductionType::PROD) {
                initial_value = 1;
              }

              if (output_shape.size() > 1) {
                segment_reduce_forward_kernel<scalar_t>
                    <<<num_blocks,
                       threads_per_block,
                       0,
                       at::cuda::getCurrentCUDAStream()>>>(
                        reduction,
                        output_data_ptr,
                        data_data_ptr,
                        lengths_data_ptr,
                        offsets_data_ptr,
                        segment_count,
                        lengths_stride_axis,
                        initial.has_value(),
                        initial_value,
                        outer_offset,
                        inner_offset,
                        data_stride_axis,
                        data_size_axis,
                        output_stride_axis,
                        output_size_axis,
                        offsets_stride_axis
                      );
                C10_CUDA_KERNEL_LAUNCH_CHECK();
              } else {
                if (reduction == SegmentReductionType::MAX) {
                  CustomMax max_op{};
                  CUB_WRAPPER(
                      cub::DeviceSegmentedReduce::Reduce,
                      data_data_ptr,
                      output_data_ptr,
                      segment_count,
                      offsets_data_ptr,
                      offsets_data_ptr + 1,
                      max_op,
                      initial_value,
                      at::cuda::getCurrentCUDAStream());
                } else if (reduction == SegmentReductionType::MEAN) {
                  CustomSum sum_op{};
                  CUB_WRAPPER(
                      cub::DeviceSegmentedReduce::Reduce,
                      data_data_ptr,
                      output_data_ptr,
                      segment_count,
                      offsets_data_ptr,
                      offsets_data_ptr + 1,
                      sum_op,
                      initial_value,
                      at::cuda::getCurrentCUDAStream());

                  post_sum_div_kernel<scalar_t>
                      <<<num_blocks,
                         threads_per_block,
                         0,
                         at::cuda::getCurrentCUDAStream()>>>(
                          output_data_ptr,
                          lengths_data_ptr,
                          segment_count,
                          initial.has_value(),
                          initial_value);
                  C10_CUDA_KERNEL_LAUNCH_CHECK();
                } else if (reduction == SegmentReductionType::MIN) {
                  CustomMin min_op{};
                  CUB_WRAPPER(
                      cub::DeviceSegmentedReduce::Reduce,
                      data_data_ptr,
                      output_data_ptr,
                      segment_count,
                      offsets_data_ptr,
                      offsets_data_ptr + 1,
                      min_op,
                      initial_value,
                      at::cuda::getCurrentCUDAStream());
                } else if (reduction == SegmentReductionType::SUM) {
                  CustomSum sum_op{};
                  CUB_WRAPPER(
                      cub::DeviceSegmentedReduce::Reduce,
                      data_data_ptr,
                      output_data_ptr,
                      segment_count,
                      offsets_data_ptr,
                      offsets_data_ptr + 1,
                      sum_op,
                      initial_value,
                      at::cuda::getCurrentCUDAStream());
                } else if (reduction == SegmentReductionType::PROD) {
                  CustomProd prod_op{};
                  CUB_WRAPPER(
                      cub::DeviceSegmentedReduce::Reduce,
                      data_data_ptr,
                      output_data_ptr,
                      segment_count,
                      offsets_data_ptr,
                      offsets_data_ptr + 1,
                      prod_op,
                      initial_value,
                      at::cuda::getCurrentCUDAStream());
                }
              }
            });
      }));

  return output;
}

REGISTER_DISPATCH(_segment_reduce_stub, &_segment_reduce_cuda_kernel);
REGISTER_DISPATCH(
    _segment_reduce_backward_stub,
    &_segment_reduce_cuda_backward_kernel);

} // namespace native
} // namespace at
