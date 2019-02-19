const Torus32 = Int32


function rand_uniform_bool(rng::AbstractRNG, dims...)
    rand(rng, Int32(0):Int32(1), dims...)
end


function rand_uniform_torus32(rng::AbstractRNG, dims...)
    rand(rng, Torus32, dims...)
end


function rand_gaussian_float(rng::AbstractRNG, sigma::Float64, dims...)
    randn(rng, dims...) .* sigma
end


# Gaussian sample centered in `message`, with standard deviation `sigma`
function rand_gaussian_torus32(rng::AbstractRNG, message::Torus32, sigma::Float64, dims...)
    err = randn(rng, dims...) .* sigma
    message .+ dtot32.(err)
end


"""
Approximates the phase to the nearest message in range `[-message_space/2, message_space/2)`
in a space with `message_space` elements.
`message_space` must be a power of 2.
"""
function decode_message(phase::Torus32, message_space::Int)
    log2_ms = trailing_zeros(message_space)
    (phase + (one(Torus32) << (32 - log2_ms - 1))) >> (32 - log2_ms)
end


"""
Returns the phase of the given message in range `[-message_space/2, message_space/2)`
in a space with `message_space` elements.
`message_space` must be a power of 2.
"""
function encode_message(mu::Int, message_space::Int)
    log2_ms = trailing_zeros(message_space)
    Torus32(mu) << (32 - log2_ms)
end


"""
Converts a double in range `[-0.5, 0.5)` to `Torus32`.
"""
function dtot32(d::Float64)
    trunc(Int32, d * 2^32)
end
