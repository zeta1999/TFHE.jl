# This structure represents an integer polynomial modulo X^N+1
struct IntPolynomialArray{T}
    coefs :: T
end

IntPolynomialArray(N::Int, dims...) = IntPolynomialArray(Array{Int32}(N, dims...))


# This structure represents an torus polynomial modulo X^N+1
struct TorusPolynomialArray{T}
    coefsT :: T
end

TorusPolynomialArray(N::Int, dims...) = TorusPolynomialArray(Array{Torus32}(N, dims...))


# This structure is used for FFT operations, and is a representation
# over C of a polynomial in R[X]/X^N+1
struct LagrangeHalfCPolynomialArray{T}
    coefsC :: T
end

function LagrangeHalfCPolynomialArray(N::Int, dims...)
    @assert mod(N, 2) == 0
    LagrangeHalfCPolynomialArray(Array{Complex{Float64}}(div(N, 2), dims...))
end


flat_coefs(arr::IntPolynomialArray) = reshape(arr.coefs, size(arr.coefs, 1), length(arr))
flat_coefs(arr::TorusPolynomialArray) = reshape(arr.coefsT, size(arr.coefsT, 1), length(arr))
flat_coefs(arr::LagrangeHalfCPolynomialArray) = reshape(arr.coefsC, size(arr.coefsC, 1), length(arr))

polynomial_size(arr::IntPolynomialArray) = size(arr.coefs, 1)
polynomial_size(arr::TorusPolynomialArray) = size(arr.coefsT, 1)
polynomial_size(arr::LagrangeHalfCPolynomialArray) = size(arr.coefsC, 1) * 2

Base.size(arr::IntPolynomialArray) = size(arr.coefs)[2:end]
Base.size(arr::TorusPolynomialArray) = size(arr.coefsT)[2:end]
Base.size(arr::LagrangeHalfCPolynomialArray) = size(arr.coefsC)[2:end]

Base.length(arr::IntPolynomialArray) = prod(size(arr))
Base.length(arr::TorusPolynomialArray) = prod(size(arr))
Base.length(arr::LagrangeHalfCPolynomialArray) = prod(size(arr))

Base.reshape(arr::LagrangeHalfCPolynomialArray, dims...) =
    LagrangeHalfCPolynomialArray(reshape(arr.coefsC, size(arr.coefsC, 1), dims...))


struct RFFTPlan
    plan
    in_arr :: Array{Float64, 2}
    out_arr :: Array{Complex{Float64}, 2}

    function RFFTPlan(dim1, dim2)
        in_arr = Array{Float64, 2}(dim1, dim2)
        out_arr = Array{Complex{Float64}, 2}(div(dim1, 2) + 1, dim2)
        p = plan_rfft(in_arr, 1)
        new(p, in_arr, out_arr)
    end
end


struct IRFFTPlan
    plan
    in_arr :: Array{Complex{Float64}, 2}
    out_arr :: Array{Float64, 2}

    function IRFFTPlan(dim1, dim2)
        in_arr = Array{Complex{Float64}, 2}(div(dim1, 2) + 1, dim2)
        out_arr = Array{Float64, 2}(dim1, dim2)
        p = plan_irfft(in_arr, dim1, 1)
        new(p, in_arr, out_arr)
    end
end


function execute_fft_plan!(p::Union{RFFTPlan, IRFFTPlan})
    A_mul_B!(p.out_arr, p.plan, p.in_arr)
end


rfft_plans = Dict{Tuple{Int, Int}, RFFTPlan}()
irfft_plans = Dict{Tuple{Int, Int}, IRFFTPlan}()


function get_rfft_plan(dim1::Int, dim2::Int)
    key = (dim1, dim2)
    if !haskey(rfft_plans, key)
        p = RFFTPlan(dim1, dim2)
        rfft_plans[key] = p
        p
    else
        rfft_plans[key]
    end
end


function get_irfft_plan(dim1::Int, dim2::Int)
    key = (dim1, dim2)
    if !haskey(irfft_plans, key)
        p = IRFFTPlan(dim1, dim2)
        irfft_plans[key] = p
        p
    else
        irfft_plans[key]
    end
end


function prepare_ifft_input!(rev_in, a, coeff)
    # FIXME: when Julia is smart enough, can be replaced by:
    #rev_in[1:N,:] .= a .* coeff
    #rev_in[N+1:end,:] .= .-rev_in[1:N,:]
    N = size(a, 1)
    batch = size(a, 2)
    @inbounds @simd for q in 1:batch
        for i in 1:N
            rev_in[i,q] = a[i, q] * coeff
        end
        for i in N+1:2*N
            rev_in[i,q] = -rev_in[i-N,q]
        end
    end
end


function prepare_ifft_output!(res, rev_out)
    # FIXME: when Julia is smart enough, can be replaced by:
    #res[1:div(N,2),:] .= rev_out[2:2:N+1,:]
    N = size(rev_out, 1) - 1
    batch = size(rev_out, 2)
    @inbounds @simd for q in 1:batch
        for i in 1:div(N,2)
            res[i,q] = rev_out[2*i,q]
        end
    end
end


function ip_ifft!(result::LagrangeHalfCPolynomialArray, p::IntPolynomialArray)
    res = flat_coefs(result)
    a = flat_coefs(p)
    N = polynomial_size(p)

    pl = get_rfft_plan(2 * N, length(p))

    prepare_ifft_input!(pl.in_arr, a, 1 / 2)
    execute_fft_plan!(pl)
    prepare_ifft_output!(res, pl.out_arr)
end


function tp_ifft!(result::LagrangeHalfCPolynomialArray, p::TorusPolynomialArray)
    res = flat_coefs(result)
    a = flat_coefs(p)
    N = polynomial_size(p)

    pl = get_rfft_plan(2 * N, length(p))

    prepare_ifft_input!(pl.in_arr, a, 1 / 2^33)
    execute_fft_plan!(pl)
    prepare_ifft_output!(res, pl.out_arr)
end


function prepare_fft_input!(fw_in, a)
    # FIXME: when Julia is smart enough, can be replaced by:
    #fw_in[1:2:N+1,:] .= 0
    #fw_in[2:2:N+1,:] .= a
    N_over_2 = size(a, 1)
    batch = size(a, 2)
    @inbounds @simd for q in 1:batch
        for i in 1:N_over_2
            fw_in[2*i-1,q] = 0
            fw_in[2*i,q] = a[i,q]
        end
        fw_in[N_over_2*2+1,q] = 0
    end
end


function prepare_fft_output!(res, fw_out, coeff)
    # FIXME: when Julia is smart enough, can be replaced by:
    #res .= to_int32.(fw_out[1:N, :] .* coeff)
    N = size(res, 1)
    batch = size(res, 2)
    @inbounds @simd for q in 1:batch
        for i in 1:N
            res[i,q] = to_int32(fw_out[i,q] * coeff)
        end
    end
end


function tp_fft!(result::TorusPolynomialArray, p::LagrangeHalfCPolynomialArray)
    res = flat_coefs(result)
    a = flat_coefs(p)
    N = polynomial_size(p)

    pl = get_irfft_plan(2 * N, length(p))

    prepare_fft_input!(pl.in_arr, a)
    execute_fft_plan!(pl)

    # the first part is from the original libtfhe;
    # the second part is from a different FFT scaling in Julia
    coeff = (2^32 / N) * (2 * N)
    prepare_fft_output!(res, pl.out_arr, coeff)
end


function tp_add_mul!(
        result::TorusPolynomialArray, poly1::IntPolynomialArray, poly2::TorusPolynomialArray)

    N = polynomial_size(result)
    tmp1 = LagrangeHalfCPolynomialArray(N, size(poly1)...)
    tmp2 = LagrangeHalfCPolynomialArray(N, size(poly2)...)
    tmp3 = LagrangeHalfCPolynomialArray(N, size(result)...)
    tmpr = TorusPolynomialArray(N, size(result)...)
    ip_ifft!(tmp1, poly1)
    tp_ifft!(tmp2, poly2)
    lp_mul!(tmp3, tmp1, tmp2)
    tp_fft!(tmpr, tmp3)
    tp_add_to!(result, tmpr)
end


#MISC OPERATIONS

# sets to zero
function lp_clear!(reps::LagrangeHalfCPolynomialArray)
    reps.coefsC .= 0
end


# termwise multiplication in Lagrange space */
function lp_mul!(
        result::LagrangeHalfCPolynomialArray,
        a::LagrangeHalfCPolynomialArray,
        b::LagrangeHalfCPolynomialArray)

    result.coefsC .= a.coefsC .* b.coefsC
end


# Torus polynomial functions

# TorusPolynomial = 0
function tp_clear!(result::TorusPolynomialArray)
    result.coefsT .= 0
end

# TorusPolynomial += TorusPolynomial
function tp_add_to!(result::TorusPolynomialArray, poly2::TorusPolynomialArray)
    result.coefsT .+= poly2.coefsT
end


function _tp_mul_by_xai_minus_one!(out, ais, in_)
    N = size(out, 1)
    @inbounds @simd for i in 1:size(out, 3)
        ai = ais[i]
        if ai < N
            # FIXME: when Julia is smart enough, can be replaced by:
            #out[1:ai,:,i] .= .-in_[(N-ai+1):N,:,i] .- in_[1:ai,:,i] # sur que i-a<0
            #out[(ai+1):N,:,i] .= in_[1:(N-ai),:,i] .- in_[(ai+1):N,:,i] # sur que N>i-a>=0
            for q in 1:size(out, 2)
                for j in 1:ai
                    out[j,q,i] = -in_[N-ai+j,q,i] - in_[j,q,i] # sur que i-a<0
                end
                for j in (ai+1):N
                    out[j,q,i] = in_[j-ai,q,i] - in_[j,q,i] # sur que N>i-a>=0
                end
            end
        else
            aa = ai - N

            # FIXME: when Julia is smart enough, can be replaced by:
            #out[1:aa,:,i] .= @views (in_[(N-aa+1):N,:,i] .- in_[1:aa,:,i]) # sur que i-a<0
            #out[(aa+1):N,:,i] .= @views (.-in_[1:(N-aa),:,i] .- in_[(aa+1):N,:,i]) # sur que N>i-a>=0
            for q in 1:size(out, 2)
                for j in 1:aa
                    out[j,q,i] = in_[N-aa+j,q,i] - in_[j,q,i] # sur que i-a<0
                end
                for j in (aa+1):N
                    out[j,q,i] = -in_[j-aa,q,i] - in_[j,q,i] # sur que N>i-a>=0
                end
            end
        end
    end
end


# result = (X^ai-1) * source
function tp_mul_by_xai_minus_one!(
        result::TorusPolynomialArray, ais::Array{Int32, 1}, source::TorusPolynomialArray)
    # FIXME: currently Julia needs a function boundary to optimize the loop inside
    _tp_mul_by_xai_minus_one!(result.coefsT, ais, source.coefsT)
end


function _tp_mul_by_xai!(out, ais, in_)
    N = size(out, 1)
    @inbounds @simd for i in 1:size(out, 2)
        ai = ais[i]
        if ai < N
            # FIXME: when Julia is smart enough, can be replaced by:
            #out[1:ai,i] .= .-in_[(N-ai+1):N,i] # sur que i-a<0
            #out[(ai+1):N,i] .= in_[1:(N-ai),i] # sur que N>i-a>=0
            for j in 1:ai
                out[j,i] = -in_[N-ai+j,i] # sur que i-a<0
            end
            for j in (ai+1):N
                out[j,i] = in_[j-ai,i] # sur que N>i-a>=0
            end
        else
            aa = ai - N

            # FIXME: when Julia is smart enough, can be replaced by:
            #out[1:aa,i] .= in_[(N-aa+1):N,i] # sur que i-a<0
            #out[(aa+1):N,i] .= .-in_[1:(N-aa),i] # sur que N>i-a>=0
            for j in 1:aa
                out[j,i] = in_[N-aa+j,i] # sur que i-a<0
            end
            for j in (aa+1):N
                out[j,i] = -in_[j-aa,i] # sur que N>i-a>=0
            end
        end
    end

end


# result= X^{a}*source
function tp_mul_by_xai!(
        result::TorusPolynomialArray, ais::Array{Int32}, source::TorusPolynomialArray)
    # FIXME: currently Julia needs a function boundary to optimize the loop inside
    _tp_mul_by_xai!(result.coefsT, ais, source.coefsT)
end

