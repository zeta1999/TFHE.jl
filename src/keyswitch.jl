# extractions Ring Lwe . Lwe
function extract_lwe_key(tlwe_key::TLweKey)
    tlwe_params = tlwe_key.params
    lwe_params = tlwe_params.extracted_lweparams

    key = vcat([poly.coeffs for poly in tlwe_key.key]...)

    LweKey(lwe_params, key)
end


struct KeyswitchKey

    input_size :: Int # length of the input key: s'
    decomp_length :: Int # decomposition length
    log2_base :: Int # log_2(base)
    out_params :: LweParams # params of the output key s
    key :: Array{LweSample, 3} # the keyswitch elements: a (base-1, n, l) matrix

    function KeyswitchKey(
            rng::AbstractRNG, decomp_length::Int, log2_base::Int,
            out_key::LweKey, tgsw_key::TGswKey)

        in_key = extract_lwe_key(tgsw_key.tlwe_key)
        out_params = out_key.params
        lwe_len = in_key.params.len

        base = 1 << log2_base

        # Generate centred noises
        alpha = out_key.params.min_noise
        noise = rand_gaussian_float(rng, alpha, lwe_len, decomp_length, base-1)
        noise .-= sum(noise) / length(noise) # recentre

        # generate the keyswitch key
        # ks[h,j,i] encodes k.s[i]/base^(j+1) where `s` is the secret key.
        # (We're not storing the values for `h == 0`
        # since they will not be used during keyswitching)
        message(i,j,h) = (in_key.key[i] * Int32(h)) << (32 - j * log2_base)
        ks = [
            lwe_encrypt(rng, message(i,j,h), noise[i,j,h], alpha, out_key)
            for h in 1:base-1, j in 1:decomp_length, i in 1:lwe_len]

        new(lwe_len, decomp_length, log2_base, out_params, ks)
    end
end


function keyswitch(ks::KeyswitchKey, sample::LweSample)
    lwe_size = ks.input_size
    log2_base = ks.log2_base
    decomp_length = ks.decomp_length

    result = lwe_noiseless_trivial(sample.b, ks.out_params)

    # Round `a` to the closest multiple of `1/2^t`, where `t` is the precision.
    # Since the real torus elements are stored as integers, adding
    # `2^32 * 1/2^t / 2 == 2^(32 - log2_base * decomp_length - 1)` sets the highmost
    # `log2_base * decomp_length` bits to the desired state
    # (similar to adding 0.5 before dropping everything to the right of the decimal point
    # when rounding a floating-point number).
    prec_offset = one(Int32) << (32 - (1 + log2_base * decomp_length))
    aibar = sample.a .+ prec_offset

    # Binary decompose the higmost bits of each `a_i`
    # into `decomp_length` values of `log2_base` bits each.
    base = one(Int32) << log2_base
    mask = base - one(Int32)
    a = [
        (ai >> (32 - j * log2_base)) & mask
        for ai in aibar, j in 1:decomp_length]

    # Translate the message of the result sample by -sum(a[i].s[i])
    # where s is the secret embedded in keyswitch key.
    for i in 1:lwe_size
        for j in 1:decomp_length
            if a[i,j] != 0
                result -= ks.key[a[i,j],j,i]
            end
        end
    end

    result
end