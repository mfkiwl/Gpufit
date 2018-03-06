#include "cpufit.h"
#include "../Gpufit/constants.h"
#include "lm_fit.h"

#include <vector>
#include <numeric>
#include <algorithm>

LMFitCPP::LMFitCPP(
    float const tolerance,
    std::size_t const fit_index,
    float const * data,
    float const * weight,
    Info const & info,
    float const * initial_parameters,
    int const * parameters_to_fit,
    char * user_info,
    float * output_parameters,
    int * output_state,
    float * output_chi_square,
    int * output_n_iterations
    ) :
    fit_index_(fit_index),
    data_(data),
    weight_(weight),
    initial_parameters_(initial_parameters),
    tolerance_(tolerance),
    converged_(false),
    info_(info),
    parameters_to_fit_(parameters_to_fit),
    curve_(info.n_points_),
    derivatives_(info.n_points_*info.n_parameters_),
    hessian_(info.n_parameters_to_fit_*info.n_parameters_to_fit_),
    modified_hessian_(info.n_parameters_to_fit_*info.n_parameters_to_fit_),
    decomposed_hessian_(info.n_parameters_to_fit_*info.n_parameters_to_fit_),
    inverted_hessian_(info.n_parameters_to_fit_*info.n_parameters_to_fit_),
    pivot_array_(info_.n_parameters_to_fit_),
    gradient_(info.n_parameters_to_fit_),
    delta_(info.n_parameters_to_fit_),
    scaling_vector_(info.n_parameters_to_fit_),
    prev_chi_square_(0),
    lambda_(0.),
    prev_parameters_(info.n_parameters_to_fit_),
    user_info_(user_info),
    parameters_(output_parameters),
    state_(output_state),
    chi_square_(output_chi_square),
    n_iterations_(output_n_iterations)
{}

template<class T>
int decompose_LUP(std::vector<T> & matrix, int const N, T const Tol, std::vector<int> & permutation_vector) {

    for (int i = 0; i < N; i++)
    {
        permutation_vector[i] = i;
    }

    for (int i = 0; i < N; i++)
    {
        T max_value = 0.f;
        int max_index = i;

        for (int k = i; k < N; k++)
        {
            T absolute_value = std::abs(matrix[k * N + i]);
            if (absolute_value > max_value)
            {
                max_value = absolute_value;
                max_index = k;
            }
        }

        if (max_value < Tol)
            return 0; //failure, matrix is degenerate

        if (max_index != i)
        {
            //pivoting permutation vector
            std::swap(permutation_vector[i], permutation_vector[max_index]);

            //pivoting rows of matrix
            for (int j = 0; j < N; j++)
            {
                std::swap(matrix[i * N + j], matrix[max_index * N + j]);
            }
        }

        for (int j = i + 1; j < N; j++)
        {
            matrix[j * N + i] /= matrix[i * N + i];

            for (int k = i + 1; k < N; k++)
            {
                matrix[j * N + k] -= matrix[j * N + i] * matrix[i * N + k];
            }
        }
    }

    return 1;
}

template<class T>
void solve_LUP(
    std::vector<T> const & matrix,
    std::vector<int> const & permutation_vector,
    std::vector<T> const & vector,
    int const N,
    std::vector<T> & solution)
{
    // solve doolittle
    for (int i = 0; i < N; i++)
    {
        solution[i] = vector[permutation_vector[i]];

        double sum = 0.f;

        for (int k = 0; k < i; k++)
        {
            sum += matrix[i * N + k] * solution[k];
        }
        solution[i] -= float(sum);
    }

    for (int i = N - 1; i >= 0; i--)
    {
        double sum = 0.f;

        for (int k = i + 1; k < N; k++)
        {
            sum += matrix[i * N + k] * solution[k];
        }
        solution[i] = (solution[i] - float(sum)) / matrix[i * N + i];
    }
}

template<class T>
void invert_LUP(
    std::vector<T> const & matrix,
    std::vector<int> const & permutation_vector,
    int const N,
    std::vector<T> & inverse)
{

    for (int j = 0; j < N; j++)
    {
        for (int i = 0; i < N; i++)
        {
            if (permutation_vector[i] == j)
            {
                inverse[i * N + j] = 1.f;
            }
            else
            {
                inverse[i * N + j] = 0.f;
            }

            for (int k = 0; k < i; k++)
            {
                inverse[i * N + j] -= matrix[i * N + k] * inverse[k * N + j];
            }
        }

        for (int i = N - 1; i >= 0; i--)
        {
            for (int k = i + 1; k < N; k++)
            {
                inverse[i * N + j] -= matrix[i * N + k] * inverse[k * N + j];
            }

            inverse[i * N + j] = inverse[i * N + j] / matrix[i * N + i];
        }
    }
}

template< class T >
T calc_euclidian_norm(std::vector<T> const & v, std::size_t size = 0)
{
    size = size ? size : v.size();

    T norm = 0.f;

    for (std::size_t i = 0; i < size; i++)
        norm += v[i] * v[i];

    norm = std::sqrt(norm);

    return norm;
}

template <class T>
void multiply_matrix_vector(
    std::vector<T> & product,
    std::vector<T> const & matrix,
    std::vector<T> const & vector)
{
    std::size_t const n_rows = matrix.size() / vector.size();
    std::size_t const n_cols = vector.size();

    for (std::size_t col = 0; col < n_cols; col++)
    {
        for (std::size_t row = 0; row < n_rows; row++)
        {
            product[row] += matrix[col * n_rows + row] * vector[col];
        }
    }
}

template< class T >
T calc_scalar_product(std::vector<T> const & v1, std::vector<T> const & v2)
{
    T product = 0.f;

    for (std::size_t i = 0; i < v1.size(); i++)
        product += v1[i] * v2[i];

    return product;
}

template< class T >
void LMFitCPP::decompose_hessian_LUP(std::vector<T> & decomposed_hessian, std::vector<T> const & hessian)
{
    decomposed_hessian = hessian;

    int const N = int(gradient_.size());

    int const singular = decompose_LUP(decomposed_hessian, info_.n_parameters_to_fit_, static_cast<T>(0), pivot_array_);
    if (singular == 0)
        *state_ = FitState::SINGULAR_HESSIAN;
}

void LMFitCPP::calc_derivatives_gauss2d(
    std::vector<float> & derivatives)
{
    std::size_t const  fit_size_x = std::size_t(std::sqrt(info_.n_points_));

    float const * p = parameters_;

    for (std::size_t y = 0; y < fit_size_x; y++)
        for (std::size_t x = 0; x < fit_size_x; x++)
        {
            float const argx = (x - p[1]) * (x - p[1]) / (2.f * p[3] * p[3]);
            float const argy = (y - p[2]) * (y - p[2]) / (2.f * p[3] * p[3]);
            float const ex = exp(-(argx + argy));

            derivatives[0 * info_.n_points_ + y*fit_size_x + x]
                = ex;
            derivatives[1 * info_.n_points_ + y*fit_size_x + x]
                = p[0] * ex * (x - p[1]) / (p[3] * p[3]);
            derivatives[2 * info_.n_points_ + y*fit_size_x + x]
                = p[0] * ex * (y - p[2]) / (p[3] * p[3]);
            derivatives[3 * info_.n_points_ + y*fit_size_x + x]
                = ex * p[0] * ((x - p[1]) * (x - p[1]) + (y - p[2]) * (y - p[2])) / (p[3] * p[3] * p[3]);
            derivatives[4 * info_.n_points_ + y*fit_size_x + x]
                = 1.f;
        }
}

void LMFitCPP::calc_derivatives_gauss2delliptic(
    std::vector<float> & derivatives)
{
    std::size_t const  fit_size_x = std::size_t(std::sqrt(info_.n_points_));

    for (std::size_t y = 0; y < fit_size_x; y++)
        for (std::size_t x = 0; x < fit_size_x; x++)
        {
            float const argx = (x - parameters_[1]) * (x - parameters_[1]) / (2.f * parameters_[3] * parameters_[3]);
            float const argy = (y - parameters_[2]) * (y - parameters_[2]) / (2.f * parameters_[4] * parameters_[4]);
            float const ex = exp(-(argx +argy));

            derivatives[0 * info_.n_points_ + y*fit_size_x + x]
                = ex;
            derivatives[1 * info_.n_points_ + y*fit_size_x + x]
                = (parameters_[0] * (x - parameters_[1])*ex) / (parameters_[3] * parameters_[3]);
            derivatives[2 * info_.n_points_ + y*fit_size_x + x]
                = (parameters_[0] * (y - parameters_[2])*ex) / (parameters_[4] * parameters_[4]);
            derivatives[3 * info_.n_points_ + y*fit_size_x + x]
                = (parameters_[0] * (x - parameters_[1])*(x - parameters_[1])*ex) / (parameters_[3] * parameters_[3] * parameters_[3]);
            derivatives[4 * info_.n_points_ + y*fit_size_x + x]
                = (parameters_[0] * (y - parameters_[2])*(y - parameters_[2])*ex) / (parameters_[4] * parameters_[4] * parameters_[4]);
            derivatives[5 * info_.n_points_ + y*fit_size_x + x]
                = 1.f;
        }
}

void LMFitCPP::calc_derivatives_gauss2drotated(
    std::vector<float> & derivatives)
{
    std::size_t const  fit_size_x = std::size_t(std::sqrt(info_.n_points_));

    float const amplitude = parameters_[0];
    float const x0 = parameters_[1];
    float const y0 = parameters_[2];
    float const sig_x = parameters_[3];
    float const sig_y = parameters_[4];
    float const background = parameters_[5];
    float const rot_sin = sin(parameters_[6]);
    float const rot_cos = cos(parameters_[6]);

    for (std::size_t y = 0; y < fit_size_x; y++)
        for (std::size_t x = 0; x < fit_size_x; x++)
        {
            float const arga = ((x - x0) * rot_cos) - ((y - y0) * rot_sin);
            float const argb = ((x - x0) * rot_sin) + ((y - y0) * rot_cos);
            float const ex = exp((-0.5f) * (((arga / sig_x) * (arga / sig_x)) + ((argb / sig_y) * (argb / sig_y))));

            derivatives[0 * info_.n_points_ + y*fit_size_x + x]
                = ex;
            derivatives[1 * info_.n_points_ + y*fit_size_x + x]
                = ex * (amplitude * rot_cos * arga / (sig_x*sig_x) + amplitude * rot_sin *argb / (sig_y*sig_y));
            derivatives[2 * info_.n_points_ + y*fit_size_x + x]
                = ex * (-amplitude * rot_sin * arga / (sig_x*sig_x) + amplitude * rot_cos *argb / (sig_y*sig_y));
            derivatives[3 * info_.n_points_ + y*fit_size_x + x]
                = ex * amplitude * arga * arga / (sig_x*sig_x*sig_x);
            derivatives[4 * info_.n_points_ + y*fit_size_x + x]
                = ex * amplitude * argb * argb / (sig_y*sig_y*sig_y);
            derivatives[5 * info_.n_points_ + y*fit_size_x + x]
                = 1.f;
            derivatives[6 * info_.n_points_ + y*fit_size_x + x]
                = ex * amplitude * arga * argb * (1.f / (sig_x*sig_x) - 1.f / (sig_y*sig_y));
        }
}

void LMFitCPP::calc_derivatives_gauss1d(
    std::vector<float> & derivatives)
{
    float * user_info_float = (float*)user_info_;
    float x = 0.f;

    for (std::size_t point_index = 0; point_index < info_.n_points_; point_index++)
    {
        if (!user_info_float)
        {
            x = float(point_index);
        }
        else if (info_.user_info_size_ / sizeof(float) == info_.n_points_)
        {
            x = user_info_float[point_index];
        }
        else if (info_.user_info_size_ / sizeof(float) > info_.n_points_)
        {
            std::size_t const fit_begin = fit_index_ * info_.n_points_;
            x = user_info_float[fit_begin + point_index];
        }

        float argx = ((x - parameters_[1])*(x - parameters_[1])) / (2.f * parameters_[2] * parameters_[2]);
        float ex = exp(-argx);

        derivatives[0 * info_.n_points_ + point_index] = ex;
        derivatives[1 * info_.n_points_ + point_index] = (parameters_[0] * (x - parameters_[1])*ex) / (parameters_[2] * parameters_[2]);
        derivatives[2 * info_.n_points_ + point_index] = (parameters_[0] * (x - parameters_[1])*(x - parameters_[1])*ex) / (parameters_[2] * parameters_[2] * parameters_[2]);
        derivatives[3 * info_.n_points_ + point_index] = 1.f;
    }
}

void LMFitCPP::calc_derivatives_cauchy2delliptic(
    std::vector<float> & derivatives)
{
    std::size_t const  fit_size_x = std::size_t(std::sqrt(info_.n_points_));

    for (std::size_t y = 0; y < fit_size_x; y++)
        for (std::size_t x = 0; x < fit_size_x; x++)
        {
            float const argx =
                ((parameters_[1] - x) / parameters_[3])
                *((parameters_[1] - x) / parameters_[3]) + 1.f;
            float const argy =
                ((parameters_[2] - y) / parameters_[4])
                *((parameters_[2] - y) / parameters_[4]) + 1.f;

            derivatives[0 * info_.n_points_ + y*fit_size_x + x]
                = 1.f / (argx*argy);
            derivatives[1 * info_.n_points_ + y*fit_size_x + x] =
                -2.f * parameters_[0] * (parameters_[1] - x)
                / (parameters_[3] * parameters_[3] * argx*argx*argy);
            derivatives[2 * info_.n_points_ + y*fit_size_x + x] =
                -2.f * parameters_[0] * (parameters_[2] - y)
                / (parameters_[4] * parameters_[4] * argy*argy*argx);
            derivatives[3 * info_.n_points_ + y*fit_size_x + x] =
                2.f * parameters_[0] * (parameters_[1] - x) * (parameters_[1] - x)
                / (parameters_[3] * parameters_[3] * parameters_[3] * argx*argx*argy);
            derivatives[4 * info_.n_points_ + y*fit_size_x + x] =
                2.f * parameters_[0] * (parameters_[2] - y) * (parameters_[2] - y)
                / (parameters_[4] * parameters_[4] * parameters_[4] * argy*argy*argx);
            derivatives[5 * info_.n_points_ + y*fit_size_x + x]
                = 1.f;
        }
}

void LMFitCPP::calc_derivatives_linear1d(
    std::vector<float> & derivatives)
{
    float * user_info_float = (float*)user_info_;
    float x = 0.f;

    for (std::size_t point_index = 0; point_index < info_.n_points_; point_index++)
    {
        if (!user_info_float)
        {
            x = float(point_index);
        }
        else if (info_.user_info_size_ / sizeof(float) == info_.n_points_)
        {
            x = user_info_float[point_index];
        }
        else if (info_.user_info_size_ / sizeof(float) > info_.n_points_)
        {
            std::size_t const fit_begin = fit_index_ * info_.n_points_;
            x = user_info_float[fit_begin + point_index];
        }

        derivatives[0 * info_.n_points_ + point_index] = 1.f;
        derivatives[1 * info_.n_points_ + point_index] = x;
    }
}

void LMFitCPP::calc_derivatives_fletcher_powell_helix(
    std::vector<float> & derivatives)
{
    float const pi = 3.14159f;

    float const * p = parameters_;

    float const arg = p[0] * p[0] + p[1] * p[1];

    // derivatives with respect to p[0]
    derivatives[0 * info_.n_points_ + 0] = 100.f * 1.f / (2.f*pi) * p[1] / arg;
    derivatives[0 * info_.n_points_ + 1] = 10.f * p[0] / std::sqrt(arg);
    derivatives[0 * info_.n_points_ + 2] = 0.f;

    // derivatives with respect to p[1]
    derivatives[1 * info_.n_points_ + 0] = -100.f * 1.f / (2.f*pi) * p[0] / (arg);
    derivatives[1 * info_.n_points_ + 1] = 10.f * p[1] / std::sqrt(arg);
    derivatives[1 * info_.n_points_ + 2] = 0.f;

    // derivatives with respect to p[2]
    derivatives[2 * info_.n_points_ + 0] = 10.f;
    derivatives[2 * info_.n_points_ + 1] = 0.f;
    derivatives[2 * info_.n_points_ + 2] = 1.f;
}

void LMFitCPP::calc_derivatives_brown_dennis(
    std::vector<float> & derivatives)
{
    float const * p = parameters_;

    for (std::size_t point_index = 0; point_index < info_.n_points_; point_index++)
    {
        float const t = static_cast<float>(point_index) / 5.f;

        float const arg1 = p[0] + p[1] * t - std::exp(t);
        float const arg2 = p[2] + p[3] * std::sin(t) - std::cos(t);

        derivatives[0 * info_.n_points_ + point_index] = 2.f * arg1;
        derivatives[1 * info_.n_points_ + point_index] = 2.f * t * arg1;
        derivatives[2 * info_.n_points_ + point_index] = 2.f * arg2;
        derivatives[3 * info_.n_points_ + point_index] = 2.f * std::sin(t) * arg2;
    }
}

void LMFitCPP::calc_derivatives_ramsey_var_p(
    std::vector<float> & derivatives)
{
    float * user_info_float = (float*)user_info_;
    float x = 0.f;

    for (std::size_t point_index = 0; point_index < info_.n_points_; point_index++)
    {
        if (!user_info_float)
        {
            x = float(point_index);
        }
        else if (info_.user_info_size_ / sizeof(float) == info_.n_points_)
        {
            x = user_info_float[point_index];
        }
        else if (info_.user_info_size_ / sizeof(float) > info_.n_points_)
        {
            std::size_t const fit_begin = fit_index_ * info_.n_points_;
            x = user_info_float[fit_begin + point_index];
        }

        // parameters: [A1 A2 c f1 f2 p t2star x1 x2] exp(-(x./t2star)^p)*(A1*cos(2*pi*f1*(x - x1)) + A2*cos(2*pi*f2*(x-x2))) + c
        float const * p = parameters_;

        float const pi = 3.14159f;
        float const t2arg = pow(x / p[6], p[5]);
        float const ex = exp(-t2arg);
        float const phasearg1 = 2.f * pi*p[3] * (x - p[7]);
        float const phasearg2 = 2.f * pi*p[4] * (x - p[8]);
        float const cos1 = cos(phasearg1);
        float const sin1 = sin(phasearg1);
        float const cos2 = cos(phasearg2);
        float const sin2 = sin(phasearg2);

        /////////////////////////// derivatives ///////////////////////////
        float * current_derivative = derivatives.data() + point_index;
        current_derivative[0 * info_.n_points_] = ex*cos1;
        current_derivative[1 * info_.n_points_] = ex*cos2;
        current_derivative[2 * info_.n_points_] = 1.f;
        current_derivative[3 * info_.n_points_] = -p[0] * 2.f * pi*(x - p[7])*ex*sin1;
        current_derivative[4 * info_.n_points_] = -p[1] * 2.f * pi*(x - p[8])*ex*sin2;
        current_derivative[5 * info_.n_points_] = -std::log(x / p[6] + 0.000001f)*ex*t2arg*(p[0] * cos1 + p[1] * cos2);
        current_derivative[6 * info_.n_points_] = p[5] * 1.f / (p[6] * p[6])*x*ex*pow(x / p[6], p[5] - 1.f)*(p[0] * cos1 + p[1] * cos2);
        current_derivative[7 * info_.n_points_] = p[0] * 2.f * pi*p[3] * sin1*ex;
        current_derivative[8 * info_.n_points_] = p[1] * 2.f * pi*p[4] * sin2*ex;
    }
}

void LMFitCPP::calc_values_cauchy2delliptic(std::vector<float>& cauchy)
{
    int const size_x = int(std::sqrt(float(info_.n_points_)));
    int const size_y = size_x;

    for (int iy = 0; iy < size_y; iy++)
    {
        for (int ix = 0; ix < size_x; ix++)
        {
            float const argx =
                ((parameters_[1] - ix) / parameters_[3])
                *((parameters_[1] - ix) / parameters_[3]) + 1.f;
            float const argy =
                ((parameters_[2] - iy) / parameters_[4])
                *((parameters_[2] - iy) / parameters_[4]) + 1.f;

            cauchy[iy*size_x + ix] = parameters_[0] / (argx * argy) + parameters_[5];
        }
    }
}

void LMFitCPP::calc_values_gauss2d(std::vector<float>& gaussian)
{
    int const size_x = int(std::sqrt(float(info_.n_points_)));
    int const size_y = size_x;

    for (int iy = 0; iy < size_y; iy++)
    {
        for (int ix = 0; ix < size_x; ix++)
        {
            float argx = (ix - parameters_[1]) * (ix - parameters_[1]) / (2.f * parameters_[3] * parameters_[3]);
            float argy = (iy - parameters_[2]) * (iy - parameters_[2]) / (2.f * parameters_[3] * parameters_[3]);
            float ex = exp(-(argx +argy));

            gaussian[iy*size_x + ix] = parameters_[0] * ex + parameters_[4];
        }
    }
}

void LMFitCPP::calc_values_gauss2delliptic(std::vector<float>& gaussian)
{
    int const size_x = int(std::sqrt(float(info_.n_points_)));
    int const size_y = size_x;
    for (int iy = 0; iy < size_y; iy++)
    {
        for (int ix = 0; ix < size_x; ix++)
        {
            float argx = (ix - parameters_[1]) * (ix - parameters_[1]) / (2.f * parameters_[3] * parameters_[3]);
            float argy = (iy - parameters_[2]) * (iy - parameters_[2]) / (2.f * parameters_[4] * parameters_[4]);
            float ex = exp(-(argx + argy));

            gaussian[iy*size_x + ix]
                = parameters_[0] * ex + parameters_[5];
        }
    }
}
    
void LMFitCPP::calc_values_gauss2drotated(std::vector<float>& gaussian)
{
    int const size_x = int(std::sqrt(float(info_.n_points_)));
    int const size_y = size_x;

    float amplitude = parameters_[0];
    float background = parameters_[5];
    float x0 = parameters_[1];
    float y0 = parameters_[2];
    float sig_x = parameters_[3];
    float sig_y = parameters_[4];
    float rot_sin = sin(parameters_[6]);
    float rot_cos = cos(parameters_[6]);

    for (int iy = 0; iy < size_y; iy++)
    {
        for (int ix = 0; ix < size_x; ix++)
        {
            int const pixel_index = iy*size_x + ix;

            float arga = ((ix - x0) * rot_cos) - ((iy - y0) * rot_sin);
            float argb = ((ix - x0) * rot_sin) + ((iy - y0) * rot_cos);

            float ex
                = exp((-0.5f) * (((arga / sig_x) * (arga / sig_x)) + ((argb / sig_y) * (argb / sig_y))));

            gaussian[pixel_index] = amplitude * ex + background;
        }
    }
}

void LMFitCPP::calc_values_gauss1d(std::vector<float>& gaussian)
{
    float * user_info_float = (float*)user_info_;
    float x = 0.f;
    for (std::size_t point_index = 0; point_index < info_.n_points_; point_index++)
    {
        if (!user_info_float)
        {
            x = float(point_index);
        }
        else if (info_.user_info_size_ / sizeof(float) == info_.n_points_)
        {
            x = user_info_float[point_index];
        }
        else if (info_.user_info_size_ / sizeof(float) > info_.n_points_)
        {
            std::size_t const fit_begin = fit_index_ * info_.n_points_;
            x = user_info_float[fit_begin + point_index];
        }

        float argx
            = ((x - parameters_[1])*(x - parameters_[1]))
            / (2.f * parameters_[2] * parameters_[2]);
        float ex = exp(-argx);
        gaussian[point_index] = parameters_[0] * ex + parameters_[3];
    }
}

void LMFitCPP::calc_values_linear1d(std::vector<float>& line)
{
    float * user_info_float = (float*)user_info_;
    float x = 0.f;
    for (std::size_t point_index = 0; point_index < info_.n_points_; point_index++)
    {
        if (!user_info_float)
        {
            x = float(point_index);
        }
        else if (info_.user_info_size_ / sizeof(float) == info_.n_points_)
        {
            x = user_info_float[point_index];
        }
        else if (info_.user_info_size_ / sizeof(float) > info_.n_points_)
        {
            std::size_t const fit_begin = fit_index_ * info_.n_points_;
            x = user_info_float[fit_begin + point_index];
        }
        line[point_index] = parameters_[0] + parameters_[1] * x;
    }
}

void LMFitCPP::calc_values_fletcher_powell_helix(std::vector<float>& values)
{
    float const * p = parameters_;

    float const pi = 3.14159f;

    float theta = 0.f;

    if (0. < p[0])
        theta = .5f * atan(p[1] / p[0]) / pi;
    else if (p[0] < 0.)
        theta = .5f * atan(p[1] / p[0]) / pi + .5f;
    else if (0. < p[1])
        theta = .25f;
    else if (p[1] < 0.)
        theta = -.25f;
    else
        theta = 0.f;

    values[0] = 10.f * (p[2] - 10.f * theta);
    values[1] = 10.f * (std::sqrt(p[0] * p[0] + p[1] * p[1]) - 1.f);
    values[2] = p[2];
}

void LMFitCPP::calc_values_brown_dennis(std::vector<float>& values)
{
    float const * p = parameters_;

    for (std::size_t point_index = 0; point_index < info_.n_points_; point_index++)
    {
        float const t = static_cast<float>(point_index) / 5.f;

        float const arg1 = p[0] + p[1] * t - std::exp(t);
        float const arg2 = p[2] + p[3] * std::sin(t) - std::cos(t);

        values[point_index] = arg1*arg1 + arg2*arg2;
    }
}

void LMFitCPP::calc_values_ramsey_var_p(std::vector<float>& values)
{
    float * user_info_float = (float*)user_info_;
    float x = 0.f;
    for (std::size_t point_index = 0; point_index < info_.n_points_; point_index++)
    {
        if (!user_info_float)
        {
            x = float(point_index);
        }
        else if (info_.user_info_size_ / sizeof(float) == info_.n_points_)
        {
            x = user_info_float[point_index];
        }
        else if (info_.user_info_size_ / sizeof(float) > info_.n_points_)
        {
            std::size_t const fit_begin = fit_index_ * info_.n_points_;
            x = user_info_float[fit_begin + point_index];
        }

        // parameters: [A1 A2 c f1 f2 p t2star x1 x2] exp(-(x./t2star)^p)*(A1*cos(2*pi*f1*(x - x1)) + A2*cos(2*pi*f2*(x-x2))) + c
        float const * p = parameters_;

        float const pi = 3.14159f;
        float const t2arg = pow(x / p[6], p[5]);
        float const ex = exp(-t2arg);
        float const phasearg1 = 2.f * pi*p[3] * (x - p[7]);
        float const phasearg2 = 2.f * pi*p[4] * (x - p[8]);
        float const cos1 = cos(phasearg1);
        float const sin1 = sin(phasearg1);
        float const cos2 = cos(phasearg2);
        float const sin2 = sin(phasearg2);
        //float const xmin = x/p[6] - 1;
        //float const log = xmin - xmin*xmin/2.f + xmin*xmin*xmin/3. - xmin*xmin*xmin*xmin/4.;

        values[point_index] = ex*(p[0] * cos1 + p[1] * cos2) + p[2]; // formula calculating fit model values
    }
}

void LMFitCPP::calc_curve_values(std::vector<float>& curve, std::vector<float>& derivatives)
{           
    if (info_.model_id_ == GAUSS_1D)
    {
        calc_values_gauss1d(curve);
        calc_derivatives_gauss1d(derivatives);
    }
    else if (info_.model_id_ == GAUSS_2D)
    {
        calc_values_gauss2d(curve);
        calc_derivatives_gauss2d(derivatives);
    }
    else if (info_.model_id_ == GAUSS_2D_ELLIPTIC)
    {
        calc_values_gauss2delliptic(curve);
        calc_derivatives_gauss2delliptic(derivatives);
    }
    else if (info_.model_id_ == GAUSS_2D_ROTATED)
    {
        calc_values_gauss2drotated(curve);
        calc_derivatives_gauss2drotated(derivatives);
    }
    else if (info_.model_id_ == CAUCHY_2D_ELLIPTIC)
    {
        calc_values_cauchy2delliptic(curve);
        calc_derivatives_cauchy2delliptic(derivatives);
    }
    else if (info_.model_id_ == LINEAR_1D)
    {
        calc_values_linear1d(curve);
        calc_derivatives_linear1d(derivatives);
    }
    else if (info_.model_id_ == FLETCHER_POWELL_HELIX)
    {
        calc_values_fletcher_powell_helix(curve);
        calc_derivatives_fletcher_powell_helix(derivatives);
    }
    else if (info_.model_id_ == BROWN_DENNIS)
    {
        calc_values_brown_dennis(curve);
        calc_derivatives_brown_dennis(derivatives);
    }
    else if (info_.model_id_ == RAMSEY_VAR_P)
    {
        calc_values_ramsey_var_p(curve);
        calc_derivatives_ramsey_var_p(derivatives);
    }
}

void LMFitCPP::calculate_hessian(
    std::vector<float> const & derivatives,
    std::vector<float> const & curve)
{
    for (int jp = 0, jhessian = 0; jp < info_.n_parameters_; jp++)
    {
        if (parameters_to_fit_[jp])
        {
            for (int ip = 0, ihessian = 0; ip < jp + 1; ip++)
            {
                if (parameters_to_fit_[ip])
                {
                    std::size_t const ijhessian
                        = ihessian * info_.n_parameters_to_fit_ + jhessian;
                    std::size_t const jihessian
                        = jhessian * info_.n_parameters_to_fit_ + ihessian;
                    std::size_t const derivatives_index_i = ip*info_.n_points_;
                    std::size_t const derivatives_index_j = jp*info_.n_points_;
                    
                    double sum = 0.;
                    for (std::size_t pixel_index = 0; pixel_index < info_.n_points_; pixel_index++)
                    {
                        if (info_.estimator_id_ == LSE)
                        {
                            if (!weight_)
                            {
                                sum
                                    += derivatives[derivatives_index_i + pixel_index]
                                    * derivatives[derivatives_index_j + pixel_index];
                            }
                            else
                            {
                                sum
                                    += derivatives[derivatives_index_i + pixel_index]
                                    * derivatives[derivatives_index_j + pixel_index]
                                    * weight_[pixel_index];
                            }
                        }
                        else if (info_.estimator_id_ == MLE)
                        {
                            sum
                                += data_[pixel_index] / (curve[pixel_index] * curve[pixel_index])
                                * derivatives[derivatives_index_i + pixel_index]
                                * derivatives[derivatives_index_j + pixel_index];
                        }
                    }
                    hessian_[ijhessian] = float(sum);
                    if (ijhessian != jihessian)
                    {
                        hessian_[jihessian]
                            = hessian_[ijhessian];
                    }
                    ihessian++;
                }
            }
            jhessian++;
        }
    }

}

void LMFitCPP::calc_gradient(
    std::vector<float> const & derivatives,
    std::vector<float> const & curve)
{

    for (int ip = 0, gradient_index = 0; ip < info_.n_parameters_; ip++)
    {
        if (parameters_to_fit_[ip])
        {
            std::size_t const derivatives_index = ip*info_.n_points_;
            double sum = 0.;
            for (std::size_t pixel_index = 0; pixel_index < info_.n_points_; pixel_index++)
            {
                float deviant = data_[pixel_index] - curve[pixel_index];

                if (info_.estimator_id_ == LSE)
                {
                    if (!weight_)
                    {
                        sum
                            += deviant * derivatives[derivatives_index + pixel_index];
                    }
                    else
                    {
                        sum
                            += deviant * derivatives[derivatives_index + pixel_index] * weight_[pixel_index];
                    }

                }
                else if (info_.estimator_id_ == MLE)
                {
                    sum
                        += -derivatives[derivatives_index + pixel_index] * (1 - data_[pixel_index] / curve[pixel_index]);
                }
            }
            gradient_[gradient_index] = float(sum);
            gradient_index++;
        }
    }

}

void LMFitCPP::calc_chi_square(
    std::vector<float> const & values)
{
    double sum = 0.;
    for (size_t pixel_index = 0; pixel_index < values.size(); pixel_index++)
    {
        float deviant = values[pixel_index] - data_[pixel_index];
        if (info_.estimator_id_ == LSE)
        {
            if (!weight_)
            {
                sum += deviant * deviant;
            }
            else
            {
                sum += deviant * deviant * weight_[pixel_index];
            }
        }
        else if (info_.estimator_id_ == MLE)
        {
            if (values[pixel_index] <= 0.)
            {
                *state_ = FitState::NEG_CURVATURE_MLE;
                return;
            }
            if (data_[pixel_index] != 0.)
            {
                sum
                    += 2. * (deviant - data_[pixel_index] * std::log(values[pixel_index] / data_[pixel_index]));
            }
            else
            {
                sum += 2. * deviant;
            }
        }
    }
    *chi_square_ = float(sum);
}

void LMFitCPP::calc_model()
{
	std::vector<float> & curve = curve_;
	std::vector<float> & derivatives = derivatives_;

	calc_curve_values(curve, derivatives);
}
    
void LMFitCPP::calc_coefficients()
{
    std::vector<float> & curve = curve_;
    std::vector<float> & derivatives = derivatives_;

    calc_chi_square(curve);

    if ((*chi_square_) < prev_chi_square_ || prev_chi_square_ == 0)
    {
        calculate_hessian(derivatives, curve);
        calc_gradient(derivatives, curve);
    }
}

void LMFitCPP::update_parameters()
{
    for (int parameter_index = 0, delta_index = 0; parameter_index < info_.n_parameters_; parameter_index++)
    {
        if (parameters_to_fit_[parameter_index])
        {
            prev_parameters_[parameter_index] = parameters_[parameter_index];
            parameters_[parameter_index] = parameters_[parameter_index] + delta_[delta_index++];
        }
    }
}

bool LMFitCPP::check_for_convergence()
{
    bool const fit_found
        = std::abs(*chi_square_ - prev_chi_square_)  < std::max(tolerance_, tolerance_ * std::abs(*chi_square_));

    return fit_found;
}

void LMFitCPP::evaluate_iteration(int const iteration)
{
    bool const max_iterations_reached = iteration == info_.max_n_iterations_ - 1;
    if (converged_ || max_iterations_reached)
    {
        (*n_iterations_) = iteration + 1;
        if (!converged_)
        {
            *state_ = FitState::MAX_ITERATION;
        }
    }
}

void LMFitCPP::prepare_next_iteration()
{
    if ((*chi_square_) < prev_chi_square_)
    {
        prev_chi_square_ = (*chi_square_);
        temp_derivatives_ = derivatives_;
    }
    else
    {
        (*chi_square_) = prev_chi_square_;
        for (int parameter_index = 0, delta_index = 0; parameter_index < info_.n_parameters_; parameter_index++)
        {
            if (parameters_to_fit_[parameter_index])
            {
                parameters_[parameter_index] = prev_parameters_[parameter_index];
            }
        }
    }
}

void LMFitCPP::modify_step_width()
{
    modified_hessian_ = hessian_;
    size_t const n_parameters = (size_t)(sqrt((float)(hessian_.size())));
    for (size_t parameter_index = 0; parameter_index < n_parameters; parameter_index++)
    {
        size_t const diagonal_index = parameter_index * n_parameters + parameter_index;

        // adaptive scaling
        scaling_vector_[parameter_index]
            = std::max(scaling_vector_[parameter_index], modified_hessian_[diagonal_index]);

        // continuous scaling
        //scaling_vector_[parameter_index] = modified_hessian_[diagonal_index];

        // initial scaling
        //if (scaling_vector_[parameter_index] == 0.)
        //    scaling_vector_[parameter_index] = modified_hessian_[diagonal_index];

        modified_hessian_[diagonal_index] += scaling_vector_[parameter_index] * lambda_;
    }
}

void LMFitCPP::initialize_step_bound()
{
    std::vector<float> scaled_parameters(info_.n_parameters_);
    std::vector<float> sqrt_scaling_vector(info_.n_parameters_);

    for (std::size_t i = 0; i < scaled_parameters.size(); i++)
    {
        sqrt_scaling_vector[i] = std::sqrt(scaling_vector_[i]);
        scaled_parameters[i] = parameters_[i] * sqrt_scaling_vector[i];
    }

    float const scaled_parameters_norm = calc_euclidian_norm(scaled_parameters);

    float const factor = 100.f;

    step_bound_ = factor * scaled_parameters_norm;

    if (step_bound_ == 0.f)
        step_bound_ = factor;
}

void LMFitCPP::update_step_bound()
{
    std::vector<float> scaled_delta(info_.n_parameters_);

    for (std::size_t i = 0; i < scaled_delta.size(); i++)
        scaled_delta[i] = delta_[i] * std::sqrt(scaling_vector_[i]);

    float const scaled_delta_norm = calc_euclidian_norm(scaled_delta);

    if (approximation_ratio_ <= .25f)
    {
        float temp = 0.f;

        if (actual_reduction_ >= 0.f)
        {
            temp = .5f;
        }
        else
        {
            temp = .5f * directive_derivative_ / (directive_derivative_ + .5f * actual_reduction_);
        }

        if (.1f * std::sqrt(*chi_square_) >= std::sqrt(prev_chi_square_) || temp < .1f)
        {
            temp = .1f;
        }


        step_bound_ = temp * std::min(step_bound_, scaled_delta_norm / .1f);
        lambda_ /= temp;
    }
    else
    {
        if (lambda_ == 0.f || approximation_ratio_ >= .75f)
        {
            step_bound_ = scaled_delta_norm / .5f;
            lambda_ = .5f * lambda_;
        }
    }
}

void LMFitCPP::initialize_lambda_bounds()
{
    // scaled delta
    std::vector<float> scaled_delta(info_.n_parameters_);
    for (std::size_t i = 0; i < scaled_delta.size(); i++)
        scaled_delta[i] = std::sqrt(scaling_vector_[i]) * delta_[i];

    // temp vector
    std::vector<float> temp(info_.n_parameters_);

    float const scaled_delta_norm = calc_euclidian_norm(scaled_delta);

    // lambda lower bound 
    lambda_lower_bound_ = phi_ / phi_derivative_;

    // lambda upper bound
    for (int i = 0; i < info_.n_parameters_; i++)
        temp[i] = gradient_[i] / std::sqrt(scaling_vector_[i]);

    float const gradient_norm = calc_euclidian_norm(temp);

    lambda_upper_bound_ = gradient_norm / step_bound_;

    // check lambda bounds
    lambda_ = std::max(lambda_, lambda_lower_bound_);
    lambda_ = std::min(lambda_, lambda_upper_bound_);

    if (lambda_ == 0.f)
        lambda_ = gradient_norm / scaled_delta_norm;
}

void LMFitCPP::update_lambda()
{
    // update bounds
    if (phi_ > .0f)
        lambda_lower_bound_ = std::max(lambda_lower_bound_, lambda_);

    if (phi_ < .0f)
        lambda_upper_bound_ = std::min(lambda_upper_bound_, lambda_);

    // update lambda
    lambda_ += (phi_ + step_bound_) / step_bound_ * phi_ / phi_derivative_;

    // check bounds
    lambda_ = std::max(lambda_lower_bound_, lambda_);
}

void LMFitCPP::calc_phi()
{
    //scaled delta
    std::vector<float> sqrt_scaling_vector(info_.n_parameters_);
    std::vector<float> scaled_delta(info_.n_parameters_);
    for (std::size_t i = 0; i < scaled_delta.size(); i++)
    {
        sqrt_scaling_vector[i] = std::sqrt(scaling_vector_[i]);
        scaled_delta[i] = sqrt_scaling_vector[i] * delta_[i];
    }

    float const scaled_delta_norm = calc_euclidian_norm(scaled_delta);

    // calculate phi
    phi_ = scaled_delta_norm - step_bound_;

    // recalculate scaled delta
    for (std::size_t i = 0; i < info_.n_parameters_; i++)
        scaled_delta[i] = scaling_vector_[i] * delta_[i];

    // calculate derivative of phi
    std::vector<float> temp(info_.n_parameters_);

    multiply_matrix_vector(temp, inverted_hessian_, scaled_delta);

    phi_derivative_
        = calc_scalar_product(temp, scaled_delta) / scaled_delta_norm;
}

void LMFitCPP::calc_approximation_quality()
{
    std::vector<float> derivatives_delta(info_.n_points_);

    multiply_matrix_vector(derivatives_delta, temp_derivatives_, delta_);

    float const & derivatives_delta_norm
        = calc_euclidian_norm(derivatives_delta);

    std::vector<float> scaled_delta(info_.n_parameters_);

    for (int i = 0; i < info_.n_parameters_; i++)
        scaled_delta[i] = delta_[i] * std::sqrt(scaling_vector_[i]);

    float const & scaled_delta_norm
        = calc_euclidian_norm(scaled_delta);

    float const summand1
        = derivatives_delta_norm * derivatives_delta_norm / prev_chi_square_;

    float summand2
        = 2.f
        * lambda_
        * scaled_delta_norm
        * scaled_delta_norm
        / prev_chi_square_;

    predicted_reduction_ = summand1 + summand2;

    directive_derivative_ = -summand1 - summand2 / 2.f;

    actual_reduction_ = -1.f;

    if (.1f * std::sqrt(*chi_square_) < std::sqrt(prev_chi_square_))
        actual_reduction_ = 1.f - *chi_square_ / prev_chi_square_;

    approximation_ratio_ = actual_reduction_ / predicted_reduction_;
}

void LMFitCPP::run()
{   
    for (int i = 0; i < info_.n_parameters_; i++)
        parameters_[i] = initial_parameters_[i];

    *state_ = FitState::CONVERGED;
	calc_model();
    temp_derivatives_ = derivatives_;
    calc_coefficients();

    prev_chi_square_ = (*chi_square_);
        
    for (int iteration = 0; (*state_) == 0; iteration++)
    {
        modify_step_width();

        if (iteration == 0)
        {
            initialize_step_bound();
        }

        decompose_hessian_LUP(decomposed_hessian_, hessian_);

        invert_LUP(decomposed_hessian_, pivot_array_, info_.n_parameters_to_fit_, inverted_hessian_);
        solve_LUP(decomposed_hessian_, pivot_array_, gradient_, info_.n_parameters_to_fit_, delta_);

        calc_phi();

        std::vector<float> sqrt_scaling_vector(info_.n_parameters_);
        std::vector<float> scaled_delta(info_.n_parameters_);
        for (std::size_t i = 0; i < scaled_delta.size(); i++)
        {
            sqrt_scaling_vector[i] = std::sqrt(scaling_vector_[i]);
            scaled_delta[i] = sqrt_scaling_vector[i] * delta_[i];
        }
        float const scaled_delta_norm = calc_euclidian_norm(scaled_delta);
        phi_derivative_ *= step_bound_ / scaled_delta_norm;

        if (phi_ > .1f * step_bound_)
        {
            initialize_lambda_bounds();

            modify_step_width();

            decompose_hessian_LUP(decomposed_hessian_, modified_hessian_);
            invert_LUP(decomposed_hessian_, pivot_array_, info_.n_parameters_to_fit_, inverted_hessian_);
            solve_LUP(decomposed_hessian_, pivot_array_, gradient_, info_.n_parameters_to_fit_, delta_);

            
            calc_phi();

            int iter_lambda = 0;

            while (std::abs(phi_) > .1f * step_bound_ && iter_lambda < 10)
            {
                update_lambda();

                modify_step_width();

                decompose_hessian_LUP(decomposed_hessian_, modified_hessian_);
                invert_LUP(decomposed_hessian_, pivot_array_, info_.n_parameters_to_fit_, inverted_hessian_);
                solve_LUP(decomposed_hessian_, pivot_array_, gradient_, info_.n_parameters_to_fit_, delta_);

                calc_phi();

                iter_lambda++;
            }
        }
        else
        {
            lambda_ = 0.f;
        }

        if (iteration == 0)
        {
            std::vector<float> scaled_delta(info_.n_parameters_);
            for (int i = 0; i < info_.n_parameters_; i++)
                scaled_delta[i] = delta_[i] * std::sqrt(scaling_vector_[i]);
            float const delta_norm = calc_euclidian_norm(scaled_delta);
            step_bound_ = std::min(step_bound_, delta_norm);
        }

        update_parameters();

		calc_model();
        calc_coefficients();

        calc_approximation_quality();

        update_step_bound();

        converged_ = check_for_convergence();

        evaluate_iteration(iteration);

        prepare_next_iteration();

        if (converged_ || *state_ != FitState::CONVERGED)
        {
            break;
        }
    }
}
