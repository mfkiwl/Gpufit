#include "constants.h"
#include "cuda_kernels.cuh"
#include "definitions.h"
#include "models/models.cuh"
#include "estimators/estimators.cuh"

__global__ void convert_pointer(
    float ** pointer_to_pointer,
    float * pointer,
    int const n_pointers,
    int const size,
    int const * skip)
{
    int const index = blockIdx.x * blockDim.x + threadIdx.x;

    if (index >= n_pointers)
        return;

    int const begin = index * size;

    pointer_to_pointer[index] = pointer + begin;
}

/* Description of the cuda_calc_curve_values function
* ===================================================
*
* This function calls one of the fitting curve functions depending on the input
* parameter model_id. The fitting curve function calculates the values of
* the fitting curves and its partial derivatives with respect to the fitting
* curve parameters. Multiple fits are calculated in parallel.
*
* Parameters:
*
* parameters: An input vector of concatenated sets of model parameters.
*
* n_fits: The number of fits.
*
* n_points: The number of data points per fit.
*
* n_parameters: The number of curve parameters.
*
* finished: An input vector which allows the calculation to be skipped for single
*           fits.
*
* values: An output vector of concatenated sets of model function values.
*
* derivatives: An output vector of concatenated sets of model function partial
*              derivatives.
*
* n_fits_per_block: The number of fits calculated by each thread block.
*
* n_blocks_per_fit: The number of thread blocks used to calculate one fit.
*
* model_id: The fitting model ID.
*
* chunk_index: The data chunk index.
*
* user_info: An input vector containing user information.
*
* user_info_size: The size of user_info in bytes.
*
* Calling the cuda_calc_curve_values function
* ===========================================
*
* When calling the function, the blocks and threads must be set up correctly,
* as shown in the following example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   threads.x = n_points * n_fits_per_block / n_blocks_per_fit;
*   blocks.x = n_fits / n_fits_per_block * n_blocks_per_fit;
*
*   cuda_calc_curve_values<<< blocks, threads >>>(
*       parameters,
*       n_fits,
*       n_points,
*       n_parameters,
*       finished,
*       values,
*       derivatives,
*       n_fits_per_block,
*       n_blocks_per_fit,
*       model_id,
*       chunk_index,
*       user_info,
*       user_info_size);
*
*/

__global__ void cuda_calc_curve_values(
    float const * parameters,
    int const n_fits,
    int const n_points,
    int const n_parameters,
    int const * finished,
    float * values,
    float * derivatives,
    int const n_fits_per_block,
    int const n_blocks_per_fit,
    ModelID const model_id,
    int const chunk_index,
    char * user_info,
    std::size_t const user_info_size)
{
    int const fit_in_block = threadIdx.x / n_points;
    int const fit_index = blockIdx.x * n_fits_per_block / n_blocks_per_fit + fit_in_block;
    int const fit_piece = blockIdx.x % n_blocks_per_fit;
    int const point_index = threadIdx.x - fit_in_block * n_points + fit_piece * blockDim.x;
    int const first_point = fit_index * n_points;

    float * current_values = values + first_point;
    float * current_derivatives = derivatives + first_point * n_parameters;
    float const * current_parameters = parameters + fit_index * n_parameters;

    if (finished[fit_index])
        return;
    if (point_index >= n_points)
        return;

    calculate_model(model_id, current_parameters, n_fits, n_points, current_values, current_derivatives, point_index, fit_index, chunk_index, user_info, user_info_size);
}

/* Description of the sum_up_floats function
* ==========================================
*
* This function sums up a vector of float values and stores the result at the
* first place of the vector.
*
* Parameters:
*
* shared_array: An input vector of float values. The vector must be stored
*               on the shared memory of the GPU. The size of this vector must be a
*               power of two. Use zero padding to extend it to the next highest
*               power of 2 greater than the number of elements.
*
* size: The number of elements in the input vector considering zero padding.
*
* Calling the sum_up_floats function
* ==================================
*
* This __device__ function can be only called from a __global__ function or
* an other __device__ function. When calling the function, the blocks and threads
* of the __global__ function must be set up correctly, as shown in the following
* example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   threads.x = size * vectors_per_block;
*   blocks.x = n_vectors / vectors_per_block;
*
*   global_function<<< blocks, threads >>>(parameter1, ...);
*
*/

__device__ void sum_up_floats(volatile float* shared_array, int const size)
{
    int const fit_in_block = threadIdx.x / size;
    int const point_index = threadIdx.x - (fit_in_block*size);

    int current_n_points = size >> 1;
    __syncthreads();
    while (current_n_points)
    {
        if (point_index < current_n_points)
        {
            shared_array[point_index] += shared_array[point_index + current_n_points];
        }
        current_n_points >>= 1;
        __syncthreads();
    }
}

__device__ void sum_subtotals(float * subtotals, int const n_subtotals, int const index, int const distance)
{
    float * current_subtotals = subtotals + index;

    double sum = 0.;
    for (int i = 0; i < n_subtotals; i++)
        sum += current_subtotals[i * distance];

    current_subtotals[0] = float(sum);
}


__device__ float calculate_skalar_product(
    float const * vector1,
    float const * vector2,
    int const size)
{
    double product = 0.;

    for (int i = 0; i < size; i++)
        product += vector1[i] * vector2[i];

    return float(product);
}

__global__ void cuda_calculate_interim_euclidian_norms(
    float * norms,
    float const * vectors,
    int const n_points,
    int const n_fits,
    int const n_parameters,
    int const n_parameters_to_fit,
    int const * finished,
    int const n_fits_per_block)
{
    int const shared_size = blockDim.x / n_fits_per_block;
    int const fit_in_block = threadIdx.x / shared_size;
    int const fit_piece = blockIdx.x / n_fits;
    int const fit_index = blockIdx.x * n_fits_per_block + fit_in_block - fit_piece * n_fits;
    int const point_index = threadIdx.x - fit_in_block * shared_size + fit_piece * shared_size;
    int const first_point = fit_index * n_points;

    if (finished[fit_index])
    {
        return;
    }

    float const * current_vectors = vectors + first_point * n_parameters;

    extern __shared__ float extern_array[];

    volatile float * shared_vector = extern_array + (fit_in_block - fit_piece) * shared_size;

    if (point_index >= n_points)
    {
        shared_vector[point_index] = 0.f;
    }
    else
    {
        for (int parameter_index = 0; parameter_index < n_parameters; parameter_index++)
        {
            float const * vector = current_vectors + parameter_index * n_points;

            shared_vector[point_index] = vector[point_index] * vector[point_index];

            sum_up_floats(shared_vector + fit_piece * shared_size, shared_size);
            norms[(fit_index * n_parameters_to_fit + parameter_index) + fit_piece * n_fits * n_parameters]
                = shared_vector[fit_piece * shared_size];
        }
    }
}

__global__ void cuda_complete_euclidian_norms(
    float * norms,
    int const n_blocks_per_fit,
    int const n_fits,
    int const n_parameters,
    int const * finished)
{
    int const index = blockIdx.x * blockDim.x + threadIdx.x;
    int const fit_index = index / n_parameters;

    if (fit_index >= n_fits || finished[index])
        return;

    sum_subtotals(norms, n_blocks_per_fit, index, n_fits * n_parameters);

    norms[index] = std::sqrt(norms[index]);
}


/* Description of the cuda_sum_chi_square_subtotals function
* ==========================================================
*
* This function sums up chi_square subtotals in place.
*
* Parameters:
*
* chi_squares: A vector of chi-square values for multiple fits.
*              in: subtotals
*              out: totals
*
* n_blocks_per_fit: The number of blocks used to calculate one fit. It is
*                   equivalent to the number of subtotals per fit.
*
* n_fits: The number of fits.
*
* finished: An input vector which allows the calculation to be skipped
*           for single fits.
*
* Calling the cuda_sum_chi_square_subtotals function
* ==================================================
*
* When calling the function, the blocks and threads must be set up correctly,
* as shown in the following example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   int const example_value = 256;
*
*   threads.x = min(n_fits, example_value);
*   blocks.x = int(ceil(float(n_fits) / float(threads.x)));
*
*   cuda_sum_chi_square_subtotals<<< blocks, threads >>>(
*       chi_squares,
*       n_blocks_per_fit,
*       n_fits,
*       finished);
*
*/

__global__ void cuda_sum_chi_square_subtotals(
    float * chi_squares,
    int const n_blocks_per_fit,
    int const n_fits,
    int const * finished)
{
    int const index = blockIdx.x * blockDim.x + threadIdx.x;

    if (index >= n_fits || finished[index])
        return;

    float * chi_square = chi_squares + index;

    double sum = 0.;
    for (int i = 0; i < n_blocks_per_fit; i++)
        sum += chi_square[i * n_fits];

    chi_square[0] = float(sum);
}

/* Description of the cuda_check_fit_improvement function
* =======================================================
*
* This function checks after each calculation of chi-square values whether the
* currently calculated chi-square values are lower than chi-square values calculated
* in the previous iteration and sets the iteration_failed flags.
*
* Parameters:
*
* iteration_failed: An output vector of flags which indicate whether the fitting
*                   process improved the fit in the last iteration. If yes it is set
*                   to 0 otherwise to 1.
*
* chi_squares: An input vector of chi-square values for multiple fits.
*
* prev_chi_squares: An input vector of chi-square values for multiple fits calculated
*                   in the previous iteration.
*
* n_fits: The number of fits.
*
* finished: An input vector which allows the calculation to be skipped
*           for single fits.
*
* Calling the cuda_check_fit_improvement function
* ===============================================
*
* When calling the function, the blocks and threads must be set up correctly,
* as shown in the following example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   int const example_value = 256;
*
*   threads.x = min(n_fits, example_value);
*   blocks.x = int(ceil(float(n_fits) / float(threads.x)));
*
*   cuda_check_fit_improvement <<< blocks, threads >>>(
*       iteration_failed,
*       chi_squares,
*       prev_chi_squares,
*       n_fits,
*       finished);
*
*/

__global__ void cuda_check_fit_improvement(
    int * iteration_failed,
    float const * chi_squares,
    float const * prev_chi_squares,
    int const n_fits,
    int const * finished)
{
    int const index = blockIdx.x * blockDim.x + threadIdx.x;

    if (index >= n_fits || finished[index])
        return;

    bool const prev_chi_squares_initialized = prev_chi_squares[index] != 0.f;
    bool const chi_square_decreased = (chi_squares[index] < prev_chi_squares[index]);
    if (prev_chi_squares_initialized && !chi_square_decreased)
    {
        iteration_failed[index] = 1;
    }
    else
    {
        iteration_failed[index] = 0;
    }
}

/* Description of the cuda_calculate_chi_squares function
* ========================================================
*
* This function calls one of the estimator funktions depending on the input
* parameter estimator_id. The estimator function calculates the chi-square values.
* The calcluation is performed for multiple fits in parallel.
*
* Parameters:
*
* chi_squares: An output vector of concatenated chi-square values.
*
* states: An output vector of values which indicate whether the fitting process
*         was carreid out correctly or which problem occurred. In this function
*         it is only used for MLE. It is set to 3 if a fitting curve value is
*         negative. This vector includes the states for multiple fits.
*
* data: An input vector of data for multiple fits
*
* values: An input vector of concatenated sets of model function values.
*
* weights: An input vector of values for weighting chi-square, gradient and hessian,
*          while using LSE
*
* n_points: The number of data points per fit.
*
* n_fits: The number of fits.
*
* estimator_id: The estimator ID.
*
* finished: An input vector which allows the calculation to be skipped for single
*           fits.
*
* n_fits_per_block: The number of fits calculated by each thread block.
*
* user_info: An input vector containing user information.
*
* user_info_size: The size of user_info in bytes.
*
* Calling the cuda_calculate_chi_squares function
* ================================================
*
* When calling the function, the blocks and threads must be set up correctly,
* as shown in the following example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   threads.x = power_of_two_n_points * n_fits_per_block / n_blocks_per_fit;
*   blocks.x = n_fits / n_fits_per_block * n_blocks_per_fit;
*
*   int const shared_size = sizeof(float) * threads.x;
*
*   cuda_calculate_chi_squares<<< blocks, threads, shared_size >>>(
*       chi_squares,
*       states,
*       data,
*       values,
*       weights,
*       n_points,
*       n_fits,
*       estimator_id,
*       finished,
*       n_fits_per_block,
*       user_info,
*       user_info_size);
*
*/

__global__ void cuda_calculate_chi_squares(
    float * chi_squares,
    int * states,
    float const * data,
    float const * values,
    float const * weights,
    int const n_points,
    int const n_fits,
    int const estimator_id,
    int const * finished,
    int const n_fits_per_block,
    char * user_info,
    std::size_t const user_info_size)
{
    int const shared_size = blockDim.x / n_fits_per_block;
    int const fit_in_block = threadIdx.x / shared_size;
    int const fit_piece = blockIdx.x / n_fits;
    int const fit_index = blockIdx.x * n_fits_per_block + fit_in_block - fit_piece * n_fits;
    int const point_index = threadIdx.x - fit_in_block * shared_size + fit_piece * shared_size;
    int const first_point = fit_index * n_points;

    if (finished[fit_index])
    {
        return;
    }

    float const * current_data = &data[first_point];
    float const * current_weight = weights ? &weights[first_point] : NULL;
    float const * current_value = &values[first_point];
    int * current_state = &states[fit_index];

    extern __shared__ float extern_array[];

    volatile float * shared_chi_square
        = extern_array + (fit_in_block - fit_piece) * shared_size;

    if (point_index >= n_points)
    {
        shared_chi_square[point_index] = 0.f;
    }

    if (point_index < n_points)
    {
        calculate_chi_square(
            estimator_id,
            shared_chi_square,
            point_index,
            current_data,
            current_value,
            current_weight,
            current_state,
            user_info,
            user_info_size);
    }
    shared_chi_square += fit_piece * shared_size;
    sum_up_floats(shared_chi_square, shared_size);
    chi_squares[fit_index + fit_piece * n_fits] = shared_chi_square[0];
}

/* Description of the cuda_sum_gradient_subtotals function
* ========================================================
*
* This function sums up the chi-square gradient subtotals in place.
*
* Parameters:
*
* gradients: A vector of gradient values for multiple fits.
*            in: subtotals
*            out: totals
*
* n_blocks_per_fit: The number of blocks used to calculate one fit
*
* n_fits: The number of fits.
*
* n_parameters_to_fit: The number of model parameters, that are not held fixed.
*
* skip: An input vector which allows the calculation to be skipped for single fits.
*
* finished: An input vector which allows the calculation to be skipped for single
*           fits.
*
* Calling the cuda_sum_gradient_subtotals function
* ================================================
*
* When calling the function, the blocks and threads must be set up correctly,
* as shown in the following example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   int const example_value = 256;
*
*   threads.x = min(n_fits, example_value);
*   blocks.x = int(ceil(float(n_fits) / float(threads.x)));
*
*   cuda_sum_gradient_subtotals<<< blocks,threads >>>(
*       gradients,
*       n_blocks_per_fit,
*       n_fits,
*       n_parameters_to_fit,
*       skip,
*       finished);
*
*/

__global__ void cuda_sum_gradient_subtotals(
    float * gradients,
    int const n_blocks_per_fit,
    int const n_fits,
    int const n_parameters,
    int const * skip,
    int const * finished)
{
    int const index = blockIdx.x * blockDim.x + threadIdx.x;
    int const fit_index = index / n_parameters;

    if (fit_index >= n_fits || finished[fit_index] || skip[fit_index])
        return;

    float * gradient = gradients + index;

    double sum = 0.;
    for (int i = 0; i < n_blocks_per_fit; i++)
        sum += gradient[i * n_fits * n_parameters];

    gradient[0] = float(sum);
}

/* Description of the cuda_calculate_gradients function
* =====================================================
*
* This function calls one of the gradient functions depending on the input
* parameter estimator_id. The gradient function calculates the gradient values
* of the chi-square function calling a __device__ function. The calcluation is
* performed for multiple fits in parallel.
*
* Parameters:
*
* gradients: An output vector of concatenated sets of gradient vector values.
*
* data: An input vector of data for multiple fits
*
* values: An input vector of concatenated sets of model function values.
*
* derivatives: An input vector of concatenated sets of model function partial
*              derivatives.
*
* weights: An input vector of values for weighting chi-square, gradient and hessian,
*          while using LSE
*
* n_points: The number of data points per fit.
*
* n_fits: The number of fits.
*
* n_parameters: The number of fitting curve parameters.
*
* n_parameters_to_fit: The number of fitting curve parameters, that are not held
*                      fixed.
*
* parameters_to_fit_indices: An input vector of indices of fitting curve parameters,
*                            that are not held fixed.
*
* estimator_id: The estimator ID.
*
* finished: An input vector which allows the calculation to be skipped for single
*           fits.
*
* skip: An input vector which allows the calculation to be skipped for single fits.
*
* n_fits_per_block: The number of fits calculated by each thread block.
*
* user_info: An input vector containing user information.
*
* user_info_size: The number of elements in user_info.
*
* Calling the cuda_calculate_gradients function
* =============================================
*
* When calling the function, the blocks and threads must be set up correctly,
* as shown in the following example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   threads.x = power_of_two_n_points * n_fits_per_block / n_blocks_per_fit;
*   blocks.x = n_fits / n_fits_per_block * n_blocks_per_fit;
*
*   int const shared_size = sizeof(float) * threads.x;
*
*   cuda_calculate_gradients<<< blocks, threads, shared_size >>>(
*       gradients,
*       data,
*       values,
*       derivatives,
*       weight,
*       n_points,
*       n_fits,
*       n_parameters,
*       n_parameters_to_fit,
*       parameters_to_fit_indices,
*       estimator_id,
*       finished,
*       skip,
*       n_fits_per_block,
*       user_info,
*       user_info_size);
*
*/

__global__ void cuda_calculate_gradients(
    float * gradients,
    float const * data,
    float const * values,
    float const * derivatives,
    float const * weights,
    int const n_points,
    int const n_fits,
    int const n_parameters,
    int const n_parameters_to_fit,
    int const * parameters_to_fit_indices,
    int const estimator_id,
    int const * finished,
    int const * skip,
    int const n_fits_per_block,
    char * user_info,
    std::size_t const user_info_size)
{
    int const shared_size = blockDim.x / n_fits_per_block;
    int const fit_in_block = threadIdx.x / shared_size;
    int const fit_piece = blockIdx.x / n_fits;
    int const fit_index = blockIdx.x * n_fits_per_block + fit_in_block - fit_piece * n_fits;
    int const point_index = threadIdx.x - fit_in_block * shared_size + fit_piece * shared_size;
    int const first_point = fit_index * n_points;

    if (finished[fit_index] || skip[fit_index])
    {
        return;
    }

    float const * current_data = &data[first_point];
    float const * current_weight = weights ? &weights[first_point] : NULL;
    float const * current_derivative = &derivatives[first_point * n_parameters];
    float const * current_value = &values[first_point];

    extern __shared__ float extern_array[];

    volatile float * shared_gradient = extern_array + (fit_in_block - fit_piece) * shared_size;

    if (point_index >= n_points)
    {
        shared_gradient[point_index] = 0.f;
    }

    for (int parameter_index = 0; parameter_index < n_parameters_to_fit; parameter_index++)
    {
        if (point_index < n_points)
        {
            int const derivative_index = parameters_to_fit_indices[parameter_index] * n_points + point_index;

            calculate_gradient(
                estimator_id,
                shared_gradient,
                point_index,
                derivative_index,
                current_data,
                current_value,
                current_derivative,
                current_weight,
                user_info,
                user_info_size);
        }
        sum_up_floats(shared_gradient + fit_piece * shared_size, shared_size);
        gradients[(fit_index * n_parameters_to_fit + parameter_index) + fit_piece * n_fits * n_parameters_to_fit]
            = shared_gradient[fit_piece * shared_size];
    }
}

/* Description of the cuda_calculate_hessians function
* ====================================================
*
* This function calls one of the hessian function depending on the input
* parameter estimator_id. The hessian funcion calculates the hessian matrix
* values of the chi-square function calling a __device__ functions. The
* calcluation is performed for multiple fits in parallel.
*
* Parameters:
*
* hessians: An output vector of concatenated sets of hessian matrix values.
*
* data: An input vector of data for multiple fits
*
* values: An input vector of concatenated sets of model function values.
*
* derivatives: An input vector of concatenated sets of model function partial
*              derivatives.
*
* weights: An input vector of values for weighting chi-square, gradient and hessian,
*          while using LSE
*
* n_points: The number of data points per fit.
*
* n_parameters: The number of fitting curve parameters.
*
* n_parameters_to_fit: The number of fitting curve parameters, that are not held
*                      fixed.
*
* parameters_to_fit_indices: An input vector of indices of fitting curve parameters,
*                            that are not held fixed.
*
* estimator_id: The estimator ID.
*
* skip: An input vector which allows the calculation to be skipped for single fits.
*
* finished: An input vector which allows the calculation to be skipped for single
*           fits.
*
* user_info: An input vector containing user information.
*
* user_info_size: The size of user_info in bytes.
*
* Calling the cuda_calculate_hessians function
* ============================================
*
* When calling the function, the blocks and threads must be set up correctly,
* as shown in the following example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   threads.x = n_parameters_to_fit;
*   threads.y = n_parameters_to_fit;
*   blocks.x = n_fits;
*
*   cuda_calculate_hessians<<< blocks, threads >>>(
*       hessians,
*       data,
*       values,
*       derivatives,
*       weight,
*       n_points,
*       n_parameters,
*       n_parameters_to_fit,
*       parameters_to_fit_indices,
*       estimator_id,
*       skip,
*       finished,
*       user_info,
*       user_info_size);
*
*/

__global__ void cuda_calculate_hessians(
    float * hessians,
    float const * data,
    float const * values,
    float const * derivatives,
    float const * weights,
    int const n_points,
    int const n_parameters,
    int const n_parameters_to_fit,
    int const * parameters_to_fit_indices,
    int const estimator_id,
    int const * skip,
    int const * finished,
    char * user_info,
    std::size_t const user_info_size)
{
    int const fit_index = blockIdx.x;
    int const first_point = fit_index * n_points;

    int const parameter_index_i = threadIdx.x;
    int const parameter_index_j = threadIdx.y;

    if (finished[fit_index] || skip[fit_index])
    {
        return;
    }

    float * current_hessian = &hessians[fit_index * n_parameters_to_fit * n_parameters_to_fit];
    float const * current_data = &data[first_point];
    float const * current_weight = weights ? &weights[first_point] : NULL;
    float const * current_derivative = &derivatives[first_point*n_parameters];
    float const * current_value = &values[first_point];

    int const hessian_index_ij = parameter_index_i * n_parameters_to_fit + parameter_index_j;
    int const derivative_index_i = parameters_to_fit_indices[parameter_index_i] * n_points;
    int const derivative_index_j = parameters_to_fit_indices[parameter_index_j] * n_points;

    double sum = 0.;
    for (int point_index = 0; point_index < n_points; point_index++)
    {
        calculate_hessian(
            estimator_id,
            &sum,
            point_index,
            derivative_index_i + point_index,
            derivative_index_j + point_index,
            current_data,
            current_value,
            current_derivative,
            current_weight,
            user_info,
            user_info_size);
    }
    current_hessian[hessian_index_ij] = float(sum);
}

__global__ void cuda_calc_scaling_vectors(
    float * scaling_vectors,
    float const * hessians,
    int const n_parameters,
    int const * finished,
    int const n_fits_per_block)
{
    int const shared_size = blockDim.x / n_fits_per_block;
    int const fit_in_block = threadIdx.x / shared_size;
    int const parameter_index = threadIdx.x - fit_in_block * shared_size;
    int const fit_index = blockIdx.x * n_fits_per_block + fit_in_block;

    if (finished[fit_index])
    {
        return;
    }

    float * scaling_vector = scaling_vectors + fit_index * n_parameters;
    float const * hessian = hessians + fit_index * n_parameters * n_parameters;

    int const diagonal_index = parameter_index * n_parameters + parameter_index;

    // adaptive scaling
    scaling_vector[parameter_index]
        = max(scaling_vector[parameter_index], std::sqrt(hessian[diagonal_index]));

    // continuous scaling
    //scaling_vector[parameter_index] = hessian[diagonal_index];

    // initial scaling
    //if (scaling_vector[parameter_index] == 0.)
    //    scaling_vector[parameter_index] = hessian[diagonal_index];
}

__global__ void cuda_init_scaled_hessians(
    float * scaled_hessians,
    float const * hessians,
    int const n_fits,
    int const n_parameters,
    int const * finished,
    int const * lambda_accepted,
    int const * newton_step_accepted)
{
    int const size = n_parameters * n_parameters;
    int const abs_index = blockIdx.x * blockDim.x + threadIdx.x;
    int const fit_index = abs_index / size;

    if (abs_index >= n_fits * size)
        return;

    if (finished[fit_index] || lambda_accepted[fit_index])
        return;

    scaled_hessians[abs_index] = hessians[abs_index];
}

/* Description of the cuda_modify_step_widths function
* ====================================================
*
* This function midifies the diagonal elements of the hessian matrices by multiplying
* them by the factor (1+ lambda). This operation controls the step widths of the
* iteration. If the last iteration failed, befor modifying the hessian, the diagonal
* elements of the hessian are calculated back to represent unmodified values.
*
* hessians: An input and output vector of hessian matrices, which are modified by
*           the lambda values.
*
* lambdas: An input vector of values for modifying the hessians.
*
* n_parameters: The number of fitting curve parameters.
*
* iteration_failed: An input vector which indicates whether the previous iteration
*                   failed.
*
* finished: An input vector which allows the calculation to be skipped for single fits.
*
* n_fits_per_block: The number of fits calculated by each thread block.
*
* Calling the cuda_modify_step_widths function
* ============================================
*
* When calling the function, the blocks and threads must be set up correctly,
* as shown in the following example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   threads.x = n_parameters_to_fit * n_fits_per_block;
*   blocks.x = n_fits / n_fits_per_block;
*
*   cuda_modify_step_width<<< blocks, threads >>>(
*       hessians,
*       lambdas,
*       n_parameters,
*       iteration_failed,
*       finished,
*       n_fits_per_block);
*
*/

__global__ void cuda_modify_step_widths(
    float * hessians,
    float const * lambdas,
    float * scaling_vectors,
    unsigned int const n_parameters,
    int const * finished,
    int const n_fits_per_block,
    int const * lambda_accepted,
    int const * newton_step_accepted)
{
    int const shared_size = blockDim.x / n_fits_per_block;
    int const fit_in_block = threadIdx.x / shared_size;
    int const parameter_index = threadIdx.x - fit_in_block * shared_size;
    int const fit_index = blockIdx.x * n_fits_per_block + fit_in_block;

    if (finished[fit_index] || lambda_accepted[fit_index] || !newton_step_accepted[fit_index])
    {
        return;
    }

    float * hessian = &hessians[fit_index * n_parameters * n_parameters];
    float * scaling_vector = &scaling_vectors[fit_index * n_parameters];
    float const & lambda = lambdas[fit_index];

    int const diagonal_index = parameter_index * n_parameters + parameter_index;

    hessian[diagonal_index]
        = hessian[diagonal_index]
        + scaling_vector[parameter_index]
        * scaling_vector[parameter_index]
        * lambda;
}

/* Description of the cuda_update_parameters function
* ===================================================
*
* This function stores the fitting curve parameter values in prev_parameters and
* updates them after each iteration.
*
* Parameters:
*
* parameters: An input and output vector of concatenated sets of model
*             parameters.
*
* prev_parameters: An input and output vector of concatenated sets of model
*                  parameters calculated by the previous iteration.
*
* deltas: An input vector of concatenated delta values, which are added to the
*         model parameters.
*
* n_parameters_to_fit: The number of fitted curve parameters.
*
* parameters_to_fit_indices: The indices of fitted curve parameters.
*
* finished: An input vector which allows the parameter update to be skipped for single fits.
*
* n_fits_per_block: The number of fits calculated by each threadblock.
*
* Calling the cuda_update_parameters function
* ===========================================
*
* When calling the function, the blocks and threads must be set up correctly,
* as shown in the following example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   threads.x = n_parameters * n_fits_per_block;
*   blocks.x = n_fits / n_fits_per_block;
*
*   cuda_update_parameters<<< blocks, threads >>>(
*       parameters,
*       prev_parameters,
*       deltas,
*       n_parameters_to_fit,
*       parameters_to_fit_indices,
*       finished,
*       n_fits_per_block);
*
*/

__global__ void cuda_update_parameters(
    float * parameters,
    float * prev_parameters,
    float const * deltas,
    int const n_parameters_to_fit,
    int const * parameters_to_fit_indices,
    int const * finished,
    int const n_fits_per_block)
{
    int const n_parameters = blockDim.x / n_fits_per_block;
    int const fit_in_block = threadIdx.x / n_parameters;
    int const parameter_index = threadIdx.x - fit_in_block * n_parameters;
    int const fit_index = blockIdx.x * n_fits_per_block + fit_in_block;

    float * current_parameters = &parameters[fit_index * n_parameters];
    float * current_prev_parameters = &prev_parameters[fit_index * n_parameters];

    current_prev_parameters[parameter_index] = current_parameters[parameter_index];

    if (finished[fit_index])
    {
        return;
    }

    if (parameter_index >= n_parameters_to_fit)
    {
        return;
    }

    float const * current_deltas = &deltas[fit_index * n_parameters_to_fit];

    current_parameters[parameters_to_fit_indices[parameter_index]] += current_deltas[parameter_index];
}

/* Description of the cuda_check_for_convergence function
* =======================================================
*
* This function checks after each iteration whether the fits are converged or not.
* It also checks whether the set maximum number of iterations is reached.
*
* Parameters:
*
* finished: An input and output vector which allows the calculation to be skipped
*           for single fits.
*
* tolerance: The tolerance value for the convergence set by user.
*
* states: An output vector of values which indicate whether the fitting process
*         was carreid out correctly or which problem occurred. If the maximum
*         number of iterations is reached without converging, it is set to 1. If
*         the fit converged it keeps its initial value of 0.
*
* chi_squares: An input vector of chi-square values for multiple fits. Used for the
*              convergence check.
*
* prev_chi_squares: An input vector of chi-square values for multiple fits calculated
*                   in the previous iteration. Used for the convergence check.
*
* iteration: The value of the current iteration. It is compared to the value
*            of the maximum number of iteration set by user.
*
* max_n_iterations: The maximum number of iterations set by user.
*
* n_fits: The number of fits.
*
* Calling the cuda_check_for_convergence function
* ===============================================
*
* When calling the function, the blocks and threads must be set up correctly,
* as shown in the following example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   int const example_value = 256;
*
*   threads.x = min(n_fits, example_value);
*   blocks.x = int(ceil(float(n_fits) / float(threads.x)));
*
*   cuda_check_for_convergence<<< blocks, threads >>>(
*       finished,
*       tolerance,
*       states,
*       chi_squares,
*       prev_chi_squares,
*       iteration,
*       max_n_iterations,
*       n_fits);
*
*/

__global__ void cuda_check_for_convergence(
    int * finished,
    float const tolerance,
    int * states,
    float const * chi_squares,
    float const * prev_chi_squares,
    int const iteration,
    int const max_n_iterations,
    int const n_fits)
{
    int const fit_index = blockIdx.x * blockDim.x + threadIdx.x;

    if (fit_index >= n_fits)
    {
        return;
    }

    if (finished[fit_index])
    {
        return;
    }

    int const fit_found
        = abs(chi_squares[fit_index] - prev_chi_squares[fit_index])
        < tolerance * max(1., chi_squares[fit_index]);

    int const max_n_iterations_reached = iteration == max_n_iterations - 1;

    if (fit_found)
    {
        finished[fit_index] = 1;
    }
    else if (max_n_iterations_reached)
    {
        states[fit_index] = MAX_ITERATION;
    }
}

/* Description of the cuda_evaluate_iteration function
* ====================================================
*
* This function evaluates the current iteration.
*   - It marks a fit as finished if a problem occured.
*   - It saves the needed number of iterations if a fit finished.
*   - It checks if all fits finished
*
* Parameters:
*
* all_finished: An output flag, that indicates whether all fits finished.
*
* n_iterations: An output vector of needed iterations for each fit.
*
* finished: An input and output vector which allows the evaluation to be skipped
*           for single fits
*
* iteration: The values of the current iteration.
*
* states: An input vector of values which indicate whether the fitting process
*         was carreid out correctly or which problem occurred.
*
* n_fits: The number of fits.
*
* Calling the cuda_evaluate_iteration function
* ============================================
*
* When calling the function, the blocks and threads must be set up correctly,
* as shown in the following example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   int const example_value = 256;
*
*   threads.x = min(n_fits, example_value);
*   blocks.x = int(ceil(float(n_fits) / float(threads.x)));
*
*   cuda_evaluate_iteration<<< blocks, threads >>>(
*       all_finished,
*       n_iterations,
*       finished,
*       iteration,
*       states,
*       n_fits);
*
*/

__global__ void cuda_evaluate_iteration(
    int * all_finished,
    int * n_iterations,
    int * finished,
    int const iteration,
    int const * states,
    int const n_fits)
{
    int const fit_index = blockIdx.x * blockDim.x + threadIdx.x;

    if (fit_index >= n_fits)
    {
        return;
    }

    if (states[fit_index] != CONVERGED)
    {
        finished[fit_index] = 1;
    }

    if (finished[fit_index] && n_iterations[fit_index] == 0)
    {
        n_iterations[fit_index] = iteration + 1;
    }

    if (!finished[fit_index])
    {
        *all_finished = 0;
    }
}

__global__ void cuda_check_all_lambdas(
    int * all_lambdas_accepted,
    int const * finished,
    int const * lambda_accepted,
    int const * newton_step_accepted,
    int const n_fits)
{
    int const fit_index = blockIdx.x * blockDim.x + threadIdx.x;

    if (fit_index >= n_fits)
        return;

    if (finished[fit_index] || !newton_step_accepted[fit_index])
        return;

    if (!lambda_accepted[fit_index])
    {
        *all_lambdas_accepted = 0;
    }
}

/* Description of the cuda_prepare_next_iteration function
* ========================================================
*
* This function prepares the next iteration. It either updates previous
* chi-square values or sets currently calculated chi-square values and
* parameters to values calculated by the previous iteration. This function also
* updates lambda values.
*
* Parameters:
*
* lambdas: An output vector of values which control the step width by modifying
*          the diagonal elements of the hessian matrices.
*
* chi_squares: An input and output vector of chi-square values for multiple fits.
*
* prev_chi_squares: An input and output vector of chi-square values for multiple
*                   fits calculated in the previous iteration.
*
* parameters: An output vector of concatenated sets of model parameters.
*
* prev_parameters: An input vector of concatenated sets of model parameters
*                  calculated in the previous iteration.
*
* n_fits: The number of fits.
*
* n_parameters: The number of fitting curve parameters.
*
* Calling the cuda_prepare_next_iteration function
* ================================================
*
* When calling the function, the blocks and threads must be set up correctly,
* as shown in the following example code.
*
*   dim3  threads(1, 1, 1);
*   dim3  blocks(1, 1, 1);
*
*   int const example_value = 256;
*
*   threads.x = min(n_fits, example_value);
*   blocks.x = int(ceil(float(n_fits) / float(threads.x)));
*
*   cuda_prepare_next_iteration<<< blocks, threads >>>(
*       lambdas,
*       chi_squares,
*       prev_chi_squares,
*       parameters,
*       prev_parameters,
*       n_fits,
*       n_parameters);
*
*/

__global__ void cuda_prepare_next_iteration(
    float * lambdas,
    float * chi_squares,
    float * prev_chi_squares,
    float * parameters,
    float const * prev_parameters,
    int const n_fits,
    int const n_parameters)
{
    int const fit_index = blockIdx.x * blockDim.x + threadIdx.x;

    if (fit_index >= n_fits)
    {
        return;
    }

    if (chi_squares[fit_index] < prev_chi_squares[fit_index])
    {
        prev_chi_squares[fit_index] = chi_squares[fit_index];
    }
    else
    {
        chi_squares[fit_index] = prev_chi_squares[fit_index];
        for (int iparameter = 0; iparameter < n_parameters; iparameter++)
        {
            parameters[fit_index * n_parameters + iparameter] = prev_parameters[fit_index * n_parameters + iparameter];
        }
    }
}

__global__ void cuda_update_temp_derivatives(
    float * temp_derivatives,
    float const * derivatives,
    int const * iteration_failed,
    int const n_fits_per_block,
    int const n_blocks_per_fit,
    int const * finished,
    int const n_parameters,
    int const n_points)
{
    int const fit_in_block = threadIdx.x / n_points;
    int const fit_index = blockIdx.x * n_fits_per_block / n_blocks_per_fit + fit_in_block;
    int const fit_piece = blockIdx.x % n_blocks_per_fit;
    int const point_index = threadIdx.x - fit_in_block * n_points + fit_piece * blockDim.x;

    if (finished[fit_index] || iteration_failed[fit_index])
    {
        return;
    }
    if (point_index >= n_points)
    {
        return;
    }

    int const begin = fit_index * n_points * n_parameters;

    float * temp_derivative = temp_derivatives + begin;
    float const * derivative = derivatives + begin;

    for (int parameter_index = 0; parameter_index < n_parameters; parameter_index++)
    {
        int const derivative_index = parameter_index * n_points + point_index;

        temp_derivative[derivative_index] = derivative[derivative_index];
    }
}

__global__ void cuda_multiply(
    float * products,
    float const * multiplicands,
    float const * multipliers,
    int const * skip,
    int const n_vectors,
    int const vector_size,
    int const * skip_2,
    int const * not_skip_3)
{
    int const absolute_index = blockIdx.x * blockDim.x + threadIdx.x;
    int const vector_index = absolute_index / vector_size;

    if (absolute_index >= n_vectors * vector_size)
    {
        return;
    }

    if (skip[vector_index] || skip_2[vector_index] || !not_skip_3[vector_index])
    {
        return;
    }

    float & product = products[absolute_index];
    float const & multiplicand = multiplicands[absolute_index];
    float const & multiplier = multipliers[absolute_index];

    product = multiplicand * multiplier;
}

__device__ float calc_euclidian_norm(int const size, float const * vector)
{
    double sum = 0.f;
    
    for (int i = 0; i < size; i++)
        sum += vector[i]*vector[i];

    return float(sqrt(sum));
}

__global__ void cuda_multiply_matrix_vector(
    float * products,
    float const * matrices,
    float const * vectors,
    int const n_rows,
    int const n_cols,
    int const n_fits_per_block,
    int const n_blocks_per_fit,
    int const * skip)
{
    int const fit_in_block = threadIdx.x / n_rows;
    int const matrix_index = blockIdx.x * n_fits_per_block / n_blocks_per_fit + fit_in_block;
    int const fit_piece = blockIdx.x % n_blocks_per_fit;
    int const row_index = threadIdx.x - fit_in_block * n_rows + fit_piece * blockDim.x;

    if (skip[matrix_index])
        return;

    float * product = products + matrix_index * n_rows;
    float const * matrix = matrices + matrix_index * n_rows * n_cols;
    float const * vector = vectors + matrix_index * n_cols;

    product[row_index] = 0.f;
    for (int col_index = 0; col_index < n_cols; col_index++)
    {
        product[row_index] += matrix[col_index * n_rows + row_index] * vector[col_index];
    }
}

__device__ void multiply_matrix_vector(
    float * product,
    float const * matrix,
    float const * vector,
    int const row_index,
    int const n_rows,
    int const n_cols)
{
    product[row_index] = 0.f;
    for (int col_index = 0; col_index < n_cols; col_index++)
    {
        product[row_index] += matrix[col_index * n_rows + row_index] * vector[col_index];
    }
}

__device__ float calc_scalar_product(float const * v1, float const * v2, int const size)
{
    float product = 0.f;

    for (std::size_t i = 0; i < size; i++)
        product += v1[i] * v2[i];

    return product;
}

__global__ void cuda_initialize_step_bounds(
    float * step_bounds,
    float * scaled_parameters,
    int const * finished,
    int const n_fits,
    int const n_parameters)
{
    int const fit_index = blockIdx.x;

    float & step_bound = step_bounds[fit_index];
    float * current_scaled_parameters = scaled_parameters + fit_index * n_parameters;

    float const scaled_parameters_norm
        = calc_euclidian_norm(n_parameters, current_scaled_parameters);

    float const factor = 100.f;

    step_bound = factor * scaled_parameters_norm;

    if (step_bound == 0.f)
        step_bound = factor;
}

__global__ void cuda_adapt_step_bounds(
    float * step_bounds,
    float const * scaled_delta_norms,
    int const * finished,
    int const n_fits)
{
    int const fit_index = blockIdx.x * blockDim.x + threadIdx.x;

    if (finished[fit_index] || fit_index >= n_fits)
        return;

    float & step_bound = step_bounds[fit_index];
    float const & scaled_delta_norm = scaled_delta_norms[fit_index];

    step_bound = min(step_bound, scaled_delta_norm);
}

__global__ void cuda_update_step_bounds(
    float * step_bounds,
    float * lambdas,
    float const * approximation_ratios,
    float const * actual_reductions,
    float const * directive_derivatives,
    float const * chi_squares,
    float const * prev_chi_squares,
    float const * scaled_delta_norms,
    int const * finished,
    int const n_fits)
{
    int const fit_index = blockIdx.x * blockDim.x + threadIdx.x;

    if (finished[fit_index] || fit_index >= n_fits)
        return;

    float & step_bound = step_bounds[fit_index];
    float & lambda = lambdas[fit_index];
    float const & approximation_ratio = approximation_ratios[fit_index];
    float const & actual_reduction = actual_reductions[fit_index];
    float const & directive_derivative = directive_derivatives[fit_index];
    float const & chi_square = chi_squares[fit_index];
    float const & prev_chi_square = prev_chi_squares[fit_index];
    float const & scaled_delta_norm = scaled_delta_norms[fit_index];

    if (approximation_ratio <= .25f)
    {
        float temp = 0.f;

        if (actual_reduction >= 0.f)
            temp = .5f;
        else
            temp = .5f * directive_derivative / (directive_derivative + .5f * actual_reduction);

        if (.1f * std::sqrt(chi_square) >= std::sqrt(prev_chi_square) || temp < .1f)
            temp = .1f;

        step_bound = temp * min(step_bound, scaled_delta_norm / .1f);
        lambda /= temp;
    }
    else
    {
        if (lambda == 0.f || approximation_ratio >= .75f)
        {
            step_bound = scaled_delta_norm / .5f;
            lambda = .5f * lambda;
        }
    }
}

__global__ void cuda_calc_phis(
    float * phis,
    float * phi_derivatives,
    float * inverted_hessians,
    float * scaled_deltas,
    float * scaled_delta_norms,
    float * temp_vectors,
    float const * scaling_vectors,
    float const * step_bounds,
    int const n_parameters,
    int const * finished,
    int const * lambda_accepted,
    int const * newton_step_accepted,
    int const n_fits_per_block)
{
    int const fit_in_block = threadIdx.x / n_parameters;
    int const parameter_index = threadIdx.x - fit_in_block * n_parameters;
    int const fit_index = blockIdx.x * n_fits_per_block + fit_in_block;

    if (finished[fit_index] || lambda_accepted[fit_index] || !newton_step_accepted[fit_index])
        return;

    float & phi = phis[fit_index];
    float & phi_derivative = phi_derivatives[fit_index];
    float * inverted_hessian = inverted_hessians + fit_index * n_parameters * n_parameters;
    float * scaled_delta = scaled_deltas + fit_index * n_parameters;
    float & scaled_delta_norm = scaled_delta_norms[fit_index];
    float * temp_vector = temp_vectors + fit_index * n_parameters;
    float const * scaling_vector = scaling_vectors + fit_index * n_parameters;
    float const & step_bound = step_bounds[fit_index];
    
    scaled_delta_norm = calc_euclidian_norm(n_parameters, scaled_delta);

    // calculate phi
    phi = scaled_delta_norm - step_bound;

    // calculate derivative of phi
    scaled_delta[parameter_index] *= scaling_vector[parameter_index];
    
    multiply_matrix_vector(temp_vector, inverted_hessian, scaled_delta, parameter_index, n_parameters, n_parameters);
    
    phi_derivative
        = calc_scalar_product(temp_vector, scaled_delta, n_parameters) / scaled_delta_norm;
}

__global__ void cuda_adapt_phi_derivatives(
    float * phi_derivatives,
    float const * step_bounds,
    float const * scaled_delta_norms,
    int const * finished)
{
    int const fit_index = blockIdx.x * blockDim.x + threadIdx.x;

    if (finished[fit_index])
        return;

    float & phi_derivative = phi_derivatives[fit_index];
    float const & step_bound = step_bounds[fit_index];
    float const & scaled_delta_norm = scaled_delta_norms[fit_index];

    phi_derivative *= step_bound / scaled_delta_norm;
}

__global__ void cuda_check_phi(
    int * newton_step_accepted,
    float const * phis,
    float const * step_bounds,
    int const * finished,
    int const n_fits)
{
    int const fit_index = blockIdx.x * blockDim.x + threadIdx.x;

    if (finished[fit_index] || fit_index >= n_fits)
        return;

    float const & phi = phis[fit_index];
    float const & step_bound = step_bounds[fit_index];

    newton_step_accepted[fit_index]
        = int(phi > .1f * step_bound);
}

__global__ void cuda_check_abs_phi(
    int * lambda_accepted,
    int const * newton_step_accepted,
    float const * phis,
    float const * step_bounds,
    int const * finished,
    int const n_fits)
{
    int const fit_index = blockIdx.x * blockDim.x + threadIdx.x;

    if (fit_index >= n_fits || finished[fit_index])
        return;

    if (lambda_accepted[fit_index] || !newton_step_accepted[fit_index])
        return;

    float const & phi = phis[fit_index];
    float const & step_bound = step_bounds[fit_index];

    lambda_accepted[fit_index]
        = int(abs(phi) <= .1f * step_bound);
}

__global__ void cuda_init_lambda_bounds(
    float * lambdas,
    float * lambda_lower_bounds,
    float * lambda_upper_bounds,
    float * scaled_gradients,
    float const * scaled_delta_norms,
    float const * phis,
    float const * phi_derivatives,
    float const * step_bounds,
    float const * gradients,
    float const * scaling_vectors,
    int const * finished,
    int const n_fits,
    int const n_parameters,
    int const * newton_step_accepted)
{
    int const fit_index = blockIdx.x * blockDim.x + threadIdx.x;

    //if (phis[fit_index] <= .1f * step_bounds[fit_index])
    //    return;

    if (fit_index >= n_fits || finished[fit_index])
        return;

    if (!newton_step_accepted[fit_index])
    {
        lambdas[fit_index] = 0.f;
        lambda_lower_bounds[fit_index] = 0.f;
        lambda_upper_bounds[fit_index] = 0.f;
        return;
    }

    float * scaled_gradient = scaled_gradients + fit_index * n_parameters;
    float const * gradient = gradients + fit_index * n_parameters;
    float const * scaling_vector = scaling_vectors + fit_index * n_parameters;

    // lambda lower bound 
    lambda_lower_bounds[fit_index] = phis[fit_index] / phi_derivatives[fit_index];

    // lambda upper bound
    for (int i = 0; i < n_parameters; i++)
        scaled_gradient[i] = gradient[i] / scaling_vector[i];

    float const gradient_norm = calc_euclidian_norm(n_parameters, scaled_gradient);

    lambda_upper_bounds[fit_index] = gradient_norm / step_bounds[fit_index];
    
    // check lambda bounds
    lambdas[fit_index] = max(lambdas[fit_index], lambda_lower_bounds[fit_index]);
    lambdas[fit_index] = min(lambdas[fit_index], lambda_upper_bounds[fit_index]);

    if (lambdas[fit_index] == 0.f)
        lambdas[fit_index] = gradient_norm / scaled_delta_norms[fit_index];
}

__global__ void cuda_update_lambdas(
    float * lambdas,
    float * lambda_lower_bounds,
    float * lambda_upper_bounds,
    float const * phis,
    float const * phi_derivatives,
    float const * step_bounds,
    int const * finished,
    int const * lambda_accepted,
    int const * newton_step_accepted,
    int const n_fits)
{
    int const fit_index = blockIdx.x * blockDim.x + threadIdx.x;

    if (fit_index >= n_fits)
        return;

    if (finished[fit_index] || lambda_accepted[fit_index] || !newton_step_accepted[fit_index])
        return;

    // update bounds
    if (phis[fit_index] > 0.f)
        lambda_lower_bounds[fit_index]
            = max(lambda_lower_bounds[fit_index], lambdas[fit_index]);

    if (phis[fit_index] < 0.f)
        lambda_upper_bounds[fit_index]
            = min(lambda_upper_bounds[fit_index], lambdas[fit_index]);

    // update lambda
    lambdas[fit_index]
        += (phis[fit_index] + step_bounds[fit_index])
        / step_bounds[fit_index]
        * phis[fit_index]
        / phi_derivatives[fit_index];

    // check bounds
    lambdas[fit_index]
        = max(lambda_lower_bounds[fit_index], lambdas[fit_index]);
}

__global__ void cuda_calc_approximation_quality(
    float * predicted_reductions,
    float * actual_reductions,
    float * directive_derivatives,
    float * approximation_ratios,
    float * derivatives_deltas,
    float const * scaled_delta_norms,
    float const * chi_squares,
    float const * prev_chi_squares,
    float const * lambdas,
    int const * finished,
    int const n_fits,
    int const n_points)
{
    int const fit_index = blockIdx.x * blockDim.x + threadIdx.x;

    if (fit_index >= n_fits)
        return;

    if (finished[fit_index])
        return;

    float & predicted_reduction = predicted_reductions[fit_index];
    float & actual_reduction = actual_reductions[fit_index];
    float & directive_derivative = directive_derivatives[fit_index];
    float & approximation_ratio = approximation_ratios[fit_index];
    float * derivatives_delta = derivatives_deltas + fit_index * n_points;
    float const & scaled_delta_norm = scaled_delta_norms[fit_index];
    float const & chi_square = chi_squares[fit_index];
    float const & prev_chi_square = prev_chi_squares[fit_index];
    float const & lambda = lambdas[fit_index];

    float const derivatives_delta_norm
        = calc_euclidian_norm(n_points, derivatives_delta);

    float const summand1
        = derivatives_delta_norm * derivatives_delta_norm / prev_chi_square;

    float summand2
        = 2.f
        * lambda
        * scaled_delta_norm
        * scaled_delta_norm
        / prev_chi_square;

    predicted_reduction = summand1 + summand2;

    directive_derivative = -summand1 - summand2 / 2.f;

    actual_reduction = -1.f;

    if (.1f * std::sqrt(chi_square) < std::sqrt(prev_chi_square))
        actual_reduction = 1.f - chi_square / prev_chi_square;

    approximation_ratio = actual_reduction / predicted_reduction;
}