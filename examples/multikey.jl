# Based on H. Chen, I. Chillotti, and Y. Song, Y"Multi-Key Homomophic Encryption from TFHE"

using Random
using TFHE:
    Torus32, IntPolynomial, TorusPolynomial, int_polynomial, torus_polynomial,
    TransformedTorusPolynomial, inverse_transform,
    encode_message, decode_message,
    rand_uniform_bool, rand_uniform_torus32, rand_gaussian_float, dtot32, rand_gaussian_torus32,
    LweParams, TLweParams,
    LweKey, TLweKey, extract_lwe_key, lwe_phase,
    LweSample, KeyswitchKey, keyswitch, TGswKey, TGswParams, reverse_polynomial, decompose
import TFHE: forward_transform

using DarkIntegers


new_torus_polynomial(len) = TorusPolynomial(Array{Torus32}(undef, len), true)


struct MKTFHEParams
    ks_log2_base :: Int # Base bit key switching
    ks_decomp_length :: Int # dimension key switching

    stddev_rlwe :: Float64 # RLWE key standard deviation

    in_out_params :: LweParams
    tgsw_params :: TGswParams

    function MKTFHEParams()

        lwe_size = 500

        ks_decomp_length = 8 # keyswitch decomposition length
        ks_log2_base = 2 # keyswitch log2(decomposition base)

        tlwe_polynomial_degree = 1024
        tlwe_mask_size = 1

        bs_log2_base = 7 # bootstrap decomposition length
        bs_decomp_length = 4 # bootstrap log2(decomposition_base)

        stddev_lwe = 0.012467 # error stddev for LWE ciphertexts
        stddev_ks = 2.44e-5 # error stddev for keyswitch
        stddev_rlwe = 3.29e-10 # error stddev for RLWE ciphertexts
        stddev_bk = 3.29e-10 # error stddev for bootstrap

        in_out_params = LweParams(lwe_size, stddev_ks, stddev_lwe)
        tlwe_params = TLweParams(tlwe_polynomial_degree, tlwe_mask_size, stddev_bk, stddev_lwe)

        tgsw_params = TGswParams(bs_log2_base, bs_decomp_length, tlwe_params)

        new(ks_log2_base, ks_decomp_length, stddev_rlwe, in_out_params, tgsw_params)
    end
end


struct SecretKey

    params :: MKTFHEParams
    lwe_key :: LweKey

    function SecretKey(rng, params::MKTFHEParams)
        new(params, LweKey(rng, params.in_out_params))
    end
end


struct SharedKey

    params :: MKTFHEParams
    a :: Array{TorusPolynomial, 1}

    function SharedKey(rng, params::MKTFHEParams)
        decomp_length = params.tgsw_params.decomp_length
        p_degree = params.tgsw_params.tlwe_params.polynomial_degree
        new(
            params,
            [torus_polynomial(rand_uniform_torus32(rng, p_degree)) for i in 1:decomp_length])
    end
end


struct PublicKey

    params :: MKTFHEParams
    b :: Array{TorusPolynomial, 1}

    function PublicKey(rng, sk::SecretKey, tgsw_key::TGswKey, shared::SharedKey)

        params = sk.params
        decomp_length = params.tgsw_params.decomp_length
        p_degree = params.tgsw_params.tlwe_params.polynomial_degree

        # The right part of the public key is `b_i = e_i + a*s_i`,
        # where `a` is shared between the parties
        # TODO: [1] was omitted in the original! It works while k=1, but will fail otherwise
        # TODO: this is basically tgsw_encrypt_zero() for mask_size=1
        b = [tgsw_key.tlwe_key.key[1] * shared.a[i] + torus_polynomial(
                    rand_gaussian_torus32(rng, zero(Int32), params.stddev_rlwe, p_degree))
            for i in 1:decomp_length]

        new(sk.params, b)
    end
end


# TGSW sample expanded for all the parties
# Since the C matrix returned by RGSW.Expand in the paper is sparse,
# we are keeping only nonzero elements of it.
mutable struct MKTGswExpSample

    x :: Array{TorusPolynomial, 2}
    y :: Array{TorusPolynomial, 2}
    c0 :: Array{TorusPolynomial, 1}
    c1 :: Array{TorusPolynomial, 1}

    current_variance :: Float64 # avg variance of the sample
    parties :: Int
    decomp_length :: Int

    function MKTGswExpSample(tgsw_params::TGswParams, parties::Int)

        decomp_length = tgsw_params.decomp_length
        p_degree = tgsw_params.tlwe_params.polynomial_degree

        x = [new_torus_polynomial(p_degree) for i in 1:decomp_length, j in 1:parties]
        y = [new_torus_polynomial(p_degree) for i in 1:decomp_length, j in 1:parties]
        c0 = [new_torus_polynomial(p_degree) for i in 1:decomp_length]
        c1 = [new_torus_polynomial(p_degree) for i in 1:decomp_length]

        current_variance = 0.0

        new(x, y, c0, c1, current_variance, parties, decomp_length)
    end
end


mutable struct MKTransformedTGswExpSample

    x :: Array{TransformedTorusPolynomial, 2}
    y :: Array{TransformedTorusPolynomial, 2}
    c0 :: Array{TransformedTorusPolynomial, 1}
    c1 :: Array{TransformedTorusPolynomial, 1}

    current_variance :: Float64 # avg variance of the sample
    parties :: Int
    decomp_length :: Int

    MKTransformedTGswExpSample(x, y, c0, c1, current_variance, parties, decomp_length) =
        new(x, y, c0, c1, current_variance, parties, decomp_length)
end


function forward_transform(sample::MKTGswExpSample)
    MKTransformedTGswExpSample(
        forward_transform.(sample.x),
        forward_transform.(sample.y),
        forward_transform.(sample.c0),
        forward_transform.(sample.c1),
        sample.current_variance, sample.parties, sample.decomp_length)
end


# Uni-encrypted TGSW sample
mutable struct MKTGswUESample

    c0 :: Array{TorusPolynomial, 1}
    c1 :: Array{TorusPolynomial, 1}
    d0 :: Array{TorusPolynomial, 1}
    d1 :: Array{TorusPolynomial, 1}
    f0 :: Array{TorusPolynomial, 1}
    f1 :: Array{TorusPolynomial, 1}

    current_variance :: Float64 # avg variance of the sample
    decomp_length :: Int

    function MKTGswUESample(tgsw_params::TGswParams)
        decomp_length = tgsw_params.decomp_length
        p_degree = tgsw_params.tlwe_params.polynomial_degree

        c0 = [new_torus_polynomial(p_degree) for i in 1:decomp_length]
        c1 = [new_torus_polynomial(p_degree) for i in 1:decomp_length]
        d0 = [new_torus_polynomial(p_degree) for i in 1:decomp_length]
        d1 = [new_torus_polynomial(p_degree) for i in 1:decomp_length]
        f0 = [new_torus_polynomial(p_degree) for i in 1:decomp_length]
        f1 = [new_torus_polynomial(p_degree) for i in 1:decomp_length]

        current_variance = 0.0

        new(c0, c1, d0, d1, f0, f1, current_variance, decomp_length)
    end
end


# Encrypt an integer value
# In the paper: RGSW.UniEnc
# Similar to tgsw_encrypt()/tlwe_encrypt(), except the public key is supplied externally.
function mk_tgsw_encrypt(
        rng, message::Int32, alpha::Float64,
        secret_key::SecretKey, tgsw_key::TGswKey, shared_key::SharedKey, public_key::PublicKey)

    tgsw_params = public_key.params.tgsw_params
    p_degree = tgsw_params.tlwe_params.polynomial_degree
    decomp_length = tgsw_params.decomp_length

    result = MKTGswUESample(tgsw_params)

    # The shared randomness
    r = int_polynomial(rand_uniform_bool(rng, p_degree))

    # C = (c0,c1) \in T^2dg, with c0 = s_party*c1 + e_c + m*g
    for i in 1:decomp_length
        result.c1[i] = torus_polynomial(rand_uniform_torus32(rng, p_degree))

        # c0 = s_party*c1 + e_c + m*g
        # TODO: it was just key, not key[1] in the original. Hardcoded mask_size=1? Check!
        result.c0[i] = (
            torus_polynomial(rand_gaussian_torus32(rng, Int32(0), alpha, p_degree))
            + message * tgsw_params.gadget_values[i]
            + tgsw_key.tlwe_key.key[1] * result.c1[i])
    end


    # D = (d0, d1) = r*[Pkey_party | Pkey_parties] + [E0|E1] + [0|m*g] \in T^2dg
    for i in 1:decomp_length

        # d1 = r*Pkey_parties[i] + E1 + m*g[i]
        result.d1[i] = (
            torus_polynomial(rand_gaussian_torus32(rng, Int32(0), alpha, p_degree))
            + message * tgsw_params.gadget_values[i]
            + r * shared_key.a[i])

        # d0 = r*Pkey_party[i] + E0
        result.d0[i] = (
            torus_polynomial(rand_gaussian_torus32(rng, Int32(0), alpha, p_degree))
            + r * public_key.b[i])
    end


    # F = (f0,f1) \in T^2dg, with f0 = s_party*f1 + e_f + r*g
    for i in 1:decomp_length

        result.f1[i] = torus_polynomial(rand_uniform_torus32(rng, p_degree))

        # f0 = s_party*f1 + e_f + r*g
        # TODO: it was just key, not key[1] in the original. Hardcoded mask_size=1? Check!
        result.f0[i] = (
            torus_polynomial(rand_gaussian_torus32(rng, Int32(0), alpha, p_degree))
            + r * tgsw_params.gadget_values[i]
            + tgsw_key.tlwe_key.key[1] * result.f1[i])
    end

    result.current_variance = alpha^2

    result
end


# In the paper: RGSW.Expand
function mk_tgsw_expand(sample::MKTGswUESample, party::Int, public_keys::Array{PublicKey, 1})

    tgsw_params = public_keys[1].params.tgsw_params
    p_degree = tgsw_params.tlwe_params.polynomial_degree
    decomp_length = tgsw_params.decomp_length
    parties = length(public_keys)

    result = MKTGswExpSample(tgsw_params, parties)

    # Initialize: C = (0, ..., d1, ..., 0, c1, d0, ..., d0, ..., d0, c0)
    for j in 1:decomp_length
        for i in 1:parties
            result.y[j,i].coeffs .= 0
        end

        result.y[j,party].coeffs .= sample.d1[j].coeffs

        result.c1[j].coeffs .= sample.c1[j].coeffs

        for i in 1:parties
            result.x[j,i].coeffs .= sample.d0[j].coeffs
        end

        result.c0[j].coeffs .= sample.c0[j].coeffs
    end

    X = new_torus_polynomial(p_degree)
    Y = new_torus_polynomial(p_degree)
    b_temp = new_torus_polynomial(p_degree)
    u = [new_torus_polynomial(p_degree) for i in 1:decomp_length]

    for i in 1:parties
        if i != party
            for j in 1:decomp_length
                # b_temp = b_i[j] - b_party[j]
                b_temp = public_keys[i].b[j] - public_keys[party].b[j]
                # g^{-1}(b_temp) = [u_0, ...,u_dg-1]
                u = decompose(b_temp, tgsw_params)

                X.coeffs .= 0
                Y.coeffs .= 0
                for l in 1:decomp_length
                    # X = xi[j] = <g^{-1}(b_temp), f0>
                    X += u[l] * sample.f0[l]
                    # Y = yi[j] = <g^{-1}(b_temp), f1>
                    Y += u[l] * sample.f1[l]
                end

                # xi = d0 + xi
                result.x[j,i] += X
                # yi = 0 + yi
                result.y[j,i] += Y
            end
        end
    end

    # TODO: calculate the current variance correctly
    result.current_variance = sample.current_variance

    result
end


mutable struct MKLweSample

    a :: Array{Torus32, 2} # masks from all parties: (n, parties)
    b :: Torus32 # the joined phase
    current_variance :: Float64 # average noise of the sample

    MKLweSample(a::Array{Torus32, 2}, b::Torus32, cv::Float64) = new(a, b, cv)

    MKLweSample(params::LweParams, parties) =
        new(Array{Torus32}(undef, params.size, parties), Torus32(0), 0.)
end


Base.:-(x::MKLweSample, y::MKLweSample) =
    MKLweSample(x.a .- y.a, x.b - y.b, x.current_variance + y.current_variance)


function mk_keyswitch(
        ks::Array{KeyswitchKey, 1}, sample::MKLweSample, LWEparams::LweParams)
    parties = length(ks)
    result = mk_lwe_noiseless_trivial(sample.b, LWEparams, parties)
    for p in 1:parties
        temp = keyswitch(ks[p], LweSample(sample.a[:,p], Int32(0), 0.))
        result.b += temp.b
        result.a[:,p] .= temp.a
    end
    result
end


# A part of the bootstrap key generated independently by each party
# (since it involves their secret keys).
struct BootstrapKeyPart

    tgsw_params :: TGswParams
    key_uni_enc :: Array{MKTGswUESample, 1}
    public_key :: PublicKey

    function BootstrapKeyPart(
            rng, secret_key::SecretKey, tgsw_key::TGswKey,
            shared_key::SharedKey, public_key::PublicKey)

        tgsw_params = public_key.params.tgsw_params
        in_out_params = secret_key.params.in_out_params
        n = in_out_params.size

        new(tgsw_params,
            [mk_tgsw_encrypt(
                rng, secret_key.lwe_key.key[j],
                tgsw_params.tlwe_params.min_noise, secret_key, tgsw_key, shared_key, public_key)
                for j in 1:n],
            public_key)
    end
end


# A part of the cloud key (bootstrap key + keyswitch key) generated independently by each party
# (since it involves their secret keys).
struct CloudKeyPart

    params :: MKTFHEParams
    bk_part :: BootstrapKeyPart
    ks :: KeyswitchKey

    function CloudKeyPart(rng, secret_key::SecretKey, shared_key::SharedKey)
        params = secret_key.params
        tgsw_key = TGswKey(rng, params.tgsw_params)
        pk = PublicKey(rng, secret_key, tgsw_key, shared_key)
        new(
            params,
            BootstrapKeyPart(rng, secret_key, tgsw_key, shared_key, pk),
            KeyswitchKey(
                rng, params.ks_decomp_length, params.ks_log2_base,
                secret_key.lwe_key, tgsw_key))
    end
end


struct MKBootstrapKey
    tgsw_params :: TGswParams
    key :: Array{MKTransformedTGswExpSample, 2}

    function MKBootstrapKey(parts::Array{BootstrapKeyPart, 1})

        parties = length(parts)

        public_keys = [part.public_key for part in parts]

        samples = [
            mk_tgsw_expand(parts[i].key_uni_enc[j], i, public_keys)
            for j in 1:length(parts[1].key_uni_enc), i in 1:parties]

        transformed_samples = forward_transform.(samples)

        new(parts[1].tgsw_params, transformed_samples)
    end
end


struct MKCloudKey

    parties :: Int
    params :: MKTFHEParams
    bootstrap_key :: MKBootstrapKey
    keyswitch_key :: Array{KeyswitchKey, 1}

    function MKCloudKey(ck_parts::Array{CloudKeyPart, 1})
        new(
            length(ck_parts),
            ck_parts[1].params,
            MKBootstrapKey([part.bk_part for part in ck_parts]),
            [part.ks for part in ck_parts])
    end
end


function mk_encrypt(rng, secret_keys::Array{SecretKey, 1}, message::Bool)

    mu = encode_message(message ? 1 : -1, 8)

    key1 = secret_keys[1].lwe_key
    alpha = key1.params.max_noise
    parties = length(secret_keys)

    a = hcat([rand_uniform_torus32(rng, key1.params.size) for i in 1:parties]...)
    b = (rand_gaussian_torus32(rng, mu, alpha)
        + reduce(+, a .* hcat([secret_keys[i].lwe_key.key for i in 1:parties]...)))

    MKLweSample(a, b, alpha^2)
end


function mk_lwe_phase(sample::MKLweSample, lwe_keys::Array{LweKey, 1})
    parties = length(lwe_keys)
    phases = [lwe_phase(LweSample(sample.a[:,i], Torus32(0), 0.), lwe_keys[i]) for i in 1:parties]
    sample.b + reduce(+, phases)
end


function mk_decrypt(secret_keys::Array{SecretKey, 1}, sample::MKLweSample)
    mk_lwe_phase(sample, [sk.lwe_key for sk in secret_keys]) > 0
end


mutable struct MKTLweSample
    a :: Array{TorusPolynomial, 1} # mask (mask_size = 1, so length = parties)
    b :: TorusPolynomial

    current_variance :: Float64
    parties :: Int

    function MKTLweSample(tlwe_params::TLweParams, parties::Int)
        p_degree = tlwe_params.polynomial_degree

        # TODO: assumes mask_size=1 here?
        a = [new_torus_polynomial(p_degree) for i in 1:parties]
        b = new_torus_polynomial(p_degree)

        current_variance = 0.0
        new(a, b, current_variance, parties)
    end

    MKTLweSample(a, b, cv, parties) = new(a, b, cv, parties)
end


Base.:+(x::MKTLweSample, y::MKTLweSample) =
    MKTLweSample(x.a .+ y.a, x.b + y.b, x.current_variance + y.current_variance, x.parties)


Base.:-(x::MKTLweSample, y::MKTLweSample) =
    MKTLweSample(x.a .- y.a, x.b - y.b, x.current_variance + y.current_variance, x.parties)


# result = (0, ..., 0, mu)
function mk_tlwe_noiseless_trivial(mu::TorusPolynomial, tlwe_params::TLweParams, parties::Int)
    p_degree = tlwe_params.polynomial_degree
    MKTLweSample(
        [torus_polynomial(zeros(Torus32, p_degree)) for i in 1:parties],
        mu,
        0., parties)
end


function mk_shift_polynomial(sample::MKTLweSample, ai::Int32)
    MKTLweSample(
        shift_polynomial.(sample.a, ai),
        shift_polynomial(sample.b, ai),
        sample.current_variance, sample.parties)
end


function mk_tgsw_extern_mul(
        sample::MKTLweSample, exp_sample::MKTransformedTGswExpSample,
        tgsw_params::TGswParams, party::Int, parties::Int)

    result = MKTLweSample(tgsw_params.tlwe_params, parties)

    p_degree = tgsw_params.tlwe_params.polynomial_degree
    decomp_length = tgsw_params.decomp_length

    dec_a = hcat(decompose.(sample.a, Ref(tgsw_params))...)
    dec_b = decompose(sample.b, tgsw_params)

    tr_dec_a = forward_transform.(dec_a)
    tr_dec_b = forward_transform.(dec_b)

    # c'_i = g^{-1}(a_i)*d1, i<parties, i!=party
    for i in 1:parties
        result.a[i].coeffs .= 0
        if i != party
            for l in 1:decomp_length
                result.a[i] += inverse_transform(tr_dec_a[l,i] * exp_sample.y[l,party])
            end
        end
    end

    # c'_party = \sum g^{-1}(a_i)*yi + g^{-1}(b)*c1
    result.a[party].coeffs .= 0
    for i in 1:parties
        for l in 1:decomp_length
            result.a[party] += inverse_transform(tr_dec_a[l,i] * exp_sample.y[l,i])
        end
    end
    for l in 1:decomp_length
        result.a[party] += inverse_transform(tr_dec_b[l] * exp_sample.c1[l])
    end

    # c'_parties = \sum g^{-1}(a_i)*xi + g^{-1}(b)*c0
    result.b.coeffs .= 0
    for i in 1:parties
        for l in 1:decomp_length
            result.b += inverse_transform(tr_dec_a[l,i] * exp_sample.x[l,i])
        end
    end
    for l in 1:decomp_length
        result.b += inverse_transform(tr_dec_b[l] * exp_sample.c0[l])
    end

    # ORIG_TODO current_variance

    result
end


function mk_mux_rotate(
        accum::MKTLweSample, sample::MKTransformedTGswExpSample,
        barai::Int32, tgsw_params::TGswParams, party::Int, parties::Int)
    # ACC = BKi*[(X^barai-1)*ACC]+ACC
    temp_result = mk_shift_polynomial(accum, barai) - accum
    accum + mk_tgsw_extern_mul(temp_result, sample, tgsw_params, party, parties)
end


function mk_blind_rotate(accum::MKTLweSample, bk::MKBootstrapKey, bara::Array{Int32, 2})
    n, parties = size(bara)
    for i in 1:parties
        for j in 1:n
            baraij = bara[j,i]
            if baraij == 0
                continue
            end
            accum = mk_mux_rotate(accum, bk.key[j,i], baraij, bk.tgsw_params, i, parties)
        end
    end
    accum
end


function mk_tlwe_extract_sample(x::MKTLweSample)
    # Iterating over parties here, not mask elements! (mask_size = 1)
    # TODO: correct for mask_size > 1
    a = hcat([reverse_polynomial(p).coeffs for p in x.a]...)
    b = x.b.coeffs[1]
    MKLweSample(a, b, 0.) # TODO: calculate the current variance
end


function mk_blind_rotate_and_extract(
        v::TorusPolynomial, bk::MKBootstrapKey, barb::Int32, bara::Array{Int32, 2})
    parties = size(bara, 2)
    testvectbis = shift_polynomial(v, -barb)
    acc = mk_tlwe_noiseless_trivial(testvectbis, bk.tgsw_params.tlwe_params, parties)
    acc = mk_blind_rotate(acc, bk, bara)
    mk_tlwe_extract_sample(acc)
end


function mk_bootstrap_wo_keyswitch(bk::MKBootstrapKey, mu::Torus32, x::MKLweSample)

    p_degree = bk.tgsw_params.tlwe_params.polynomial_degree

    barb = decode_message(x.b, p_degree * 2)
    bara = decode_message.(x.a, p_degree * 2)

    #the initial testvec = [mu,mu,mu,...,mu]
    testvect = torus_polynomial(repeat([mu], p_degree))

    mk_blind_rotate_and_extract(testvect, bk, barb, bara)
end


function mk_bootstrap(ck::MKCloudKey, mu::Torus32, x::MKLweSample)
    u = mk_bootstrap_wo_keyswitch(ck.bootstrap_key, mu, x)
    mk_keyswitch(ck.keyswitch_key, u, ck.params.in_out_params)
end


function mk_lwe_noiseless_trivial(mu::Torus32, params::LweParams, parties::Int)
    MKLweSample(zeros(Torus32, params.size, parties), mu, 0.)
end


function mk_gate_nand(ck::MKCloudKey, x::MKLweSample, y::MKLweSample)
    temp = (
        mk_lwe_noiseless_trivial(encode_message(1, 8), ck.params.in_out_params, ck.parties)
        - x - y)
    mk_bootstrap(ck, encode_message(1, 8), temp)
end


function main()
    parties = 2

    params = MKTFHEParams()

    rng = MersenneTwister()

    # Processed on clients' machines
    secret_keys = [SecretKey(rng, params) for i in 1:parties]

    # Created by the server
    shared_key = SharedKey(rng, params)

    # Processed on clients' machines
    ck_parts = [CloudKeyPart(rng, secret_key, shared_key) for secret_key in secret_keys]

    # Processed on the server.
    # `ck_parts` only contain information `public_keys`, `secret_keys` remain secret.
    cloud_key = MKCloudKey(ck_parts)

    for trial = 1:10

        mess1 = rand(Bool)
        mess2 = rand(Bool)
        out = !(mess1 && mess2)

        enc_mess1 = mk_encrypt(rng, secret_keys, mess1)
        enc_mess2 = mk_encrypt(rng, secret_keys, mess2)

        dec_mess1 = mk_decrypt(secret_keys, enc_mess1)
        dec_mess2 = mk_decrypt(secret_keys, enc_mess2)
        @assert mess1 == dec_mess1
        @assert mess2 == dec_mess2

        enc_out = mk_gate_nand(cloud_key, enc_mess1, enc_mess2)

        dec_out = mk_decrypt(secret_keys, enc_out)
        @assert out == dec_out

        println("Trial $trial: $mess1 NAND $mess2 = $out")
    end
end


main()
