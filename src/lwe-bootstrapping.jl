struct LweBootstrappingKey
    in_out_params :: LweParams # paramètre de l'input et de l'output. key: s
    bk_params :: TGswParams # params of the Gsw elems in bk. key: s"
    accum_params :: TLweParams # params of the accum variable key: s"
    extract_params :: LweParams # params after extraction: key: s'
    bk :: Array{TGswSample, 1} # the bootstrapping key (s->s")
    ks :: LweKeySwitchKey # the keyswitch key (s'->s)

    function LweBootstrappingKey(
            ks_t::Int32, ks_basebit::Int32, in_out_params::LweParams, bk_params::TGswParams)
        accum_params = bk_params.tlwe_params
        extract_params = accum_params.extracted_lweparams
        n = in_out_params.n
        N = extract_params.n

        bk = new_TGswSample_array(n, bk_params)
        ks = LweKeySwitchKey(N, ks_t, ks_basebit, in_out_params)

        new(in_out_params, bk_params, accum_params, extract_params, bk, ks)
    end
end


struct LweBootstrappingKeyFFT
    in_out_params :: LweParams # paramètre de l'input et de l'output. key: s
    bk_params :: TGswParams # params of the Gsw elems in bk. key: s"
    accum_params :: TLweParams # params of the accum variable key: s"
    extract_params :: LweParams # params after extraction: key: s'
    bkFFT :: Array{TGswSampleFFT, 1} # the bootstrapping key (s->s")
    ks :: LweKeySwitchKey # the keyswitch key (s'->s)

    #(equivalent of the C++ constructor)
    function LweBootstrappingKeyFFT(bk::LweBootstrappingKey)

        in_out_params = bk.in_out_params
        bk_params = bk.bk_params
        accum_params = bk_params.tlwe_params
        extract_params = accum_params.extracted_lweparams
        n = in_out_params.n
        t = bk.ks.t
        basebit = bk.ks.basebit
        base = bk.ks.base
        N = extract_params.n

        ks = LweKeySwitchKey(N, t, basebit, in_out_params)
        # Copy the KeySwitching key
        for i in 0:(N-1)
            for j in 0:(t-1)
                for p in 0:(base-1)
                    lweCopy(ks.ks[p+1,j+1,i+1], bk.ks.ks[p+1,j+1,i+1], in_out_params)
                end
            end
        end

        # Bootstrapping Key FFT
        bkFFT = [TGswSampleFFT(bk_params) for i in 1:n]
        for i in 0:(n-1)
            tGswToFFTConvert(bkFFT[i+1], bk.bk[i+1], bk_params)
        end

        new(in_out_params, bk_params, accum_params, extract_params, bkFFT, ks)
    end

end


function tfhe_createLweBootstrappingKey(
        rng::AbstractRNG,
        bk::LweBootstrappingKey,
        key_in::LweKey,
        rgsw_key::TGswKey)

    @assert bk.bk_params == rgsw_key.params
    @assert bk.in_out_params == key_in.params

    in_out_params = bk.in_out_params
    bk_params = bk.bk_params
    accum_params = bk_params.tlwe_params
    extract_params = accum_params.extracted_lweparams

    #LweKeySwitchKey* ks; #/< the keyswitch key (s'.s)
    accum_key = rgsw_key.tlwe_key
    extracted_key = LweKey(extract_params)
    tLweExtractKey(extracted_key, accum_key)

    lweCreateKeySwitchKey(rng, bk.ks, extracted_key, key_in)

    # TGswSample* bk; #/< the bootstrapping key (s.s")
    kin = key_in.key
    alpha = accum_params.alpha_min
    n = in_out_params.n
    #const int32_t kpl = bk_params.kpl;
    #const int32_t k = accum_params.k;
    #n::Int32 = accum_params.N;
    #cout << "create the bootstrapping key bk ("  << "  " << n*kpl*(k+1)*N*4 << " bytes)" << endl;
    #cout << "  with noise_stdev: " << alpha << endl;
    for i in 0:(n-1)
        tGswSymEncryptInt(rng, bk.bk[i+1], kin[i+1], alpha, rgsw_key)
    end
end


function tfhe_MuxRotate_FFT(
        result::TLweSample, accum::TLweSample, bki::TGswSampleFFT, barai::Int32,
        bk_params::TGswParams)
    # ACC = BKi*[(X^barai-1)*ACC]+ACC
    # temp = (X^barai-1)*ACC
    tLweMulByXaiMinusOne(result, barai, accum, bk_params.tlwe_params)
    # temp *= BKi
    tGswFFTExternMulToTLwe(result, bki, bk_params)

    # ACC += temp
    tLweAddTo(result, accum, bk_params.tlwe_params)
end


#=
 * multiply the accumulator by X^sum(bara_i.s_i)
 * @param accum the TLWE sample to multiply
 * @param bk An array of n TGSW FFT samples where bk_i encodes s_i
 * @param bara An array of n coefficients between 0 and 2N-1
 * @param bk_params The parameters of bk
=#
function tfhe_blindRotate_FFT(accum::TLweSample,
                                 bkFFT::Array{TGswSampleFFT, 1},
                                 bara::Array{Int32, 1},
                                 n::Int32,
                                 bk_params::TGswParams)

    #TGswSampleFFT* temp = new_TGswSampleFFT(bk_params);
    temp = TLweSample(bk_params.tlwe_params)
    temp2 = temp
    temp3 = accum

    accum_in_temp3 = true

    for i in 0:(n-1)

        barai = bara[i+1]
        if barai == 0
            continue #indeed, this is an easy case!
        end

        tfhe_MuxRotate_FFT(temp2, temp3, bkFFT[i+1], barai, bk_params)

        temp2, temp3 = temp3, temp2
        accum_in_temp3 = !accum_in_temp3
    end

    if !accum_in_temp3 # temp3 != accum
        tLweCopy(accum, temp3, bk_params.tlwe_params)
    end
end


#=
 * result = LWE(v_p) where p=barb-sum(bara_i.s_i) mod 2N
 * @param result the output LWE sample
 * @param v a 2N-elt anticyclic function (represented by a TorusPolynomial)
 * @param bk An array of n TGSW FFT samples where bk_i encodes s_i
 * @param barb A coefficients between 0 and 2N-1
 * @param bara An array of n coefficients between 0 and 2N-1
 * @param bk_params The parameters of bk
=#
function tfhe_blindRotateAndExtract_FFT(result::LweSample,
                                           v::TorusPolynomial,
                                           bk::Array{TGswSampleFFT, 1},
                                           barb::Int32,
                                           bara::Array{Int32, 1},
                                           n::Int32,
                                           bk_params::TGswParams)

    accum_params = bk_params.tlwe_params
    extract_params = accum_params.extracted_lweparams
    N = accum_params.N
    _2N = Int32(2) * N

    # Test polynomial
    testvectbis = TorusPolynomial(N)
    # Accumulator
    acc = TLweSample(accum_params)

    # testvector = X^{2N-barb}*v
    if barb != 0
        torusPolynomialMulByXai(testvectbis, _2N - barb, v)
    else
        torusPolynomialCopy(testvectbis, v)
    end

    tLweNoiselessTrivial(acc, testvectbis, accum_params)

    # Blind rotation
    tfhe_blindRotate_FFT(acc, bk, bara, n, bk_params)

    # Extraction
    tLweExtractLweSample(result, acc, extract_params, accum_params)
end


#=
 * result = LWE(mu) iff phase(x)>0, LWE(-mu) iff phase(x)<0
 * @param result The resulting LweSample
 * @param bk The bootstrapping + keyswitch key
 * @param mu The output message (if phase(x)>0)
 * @param x The input sample
=#
function tfhe_bootstrap_woKS_FFT(result::LweSample,
                                    bk::LweBootstrappingKeyFFT,
                                    mu::Torus32,
                                    x::LweSample)

    bk_params = bk.bk_params
    accum_params = bk.accum_params
    in_params = bk.in_out_params
    N = accum_params.N
    Nx2 = 2 * N
    n = in_params.n

    testvect = TorusPolynomial(N)
    bara = Array{Int32, 1}(n)

    # Modulus switching
    barb = modSwitchFromTorus32(x.b, Nx2)
    for i in 0:(n-1)
        bara[i+1] = modSwitchFromTorus32(x.a[i+1], Nx2)
    end

    # the initial testvec = [mu,mu,mu,...,mu]
    for i in 0:(N-1)
        testvect.coefsT[i+1] = mu
    end

    # Bootstrapping rotation and extraction
    tfhe_blindRotateAndExtract_FFT(result, testvect, bk.bkFFT, barb, bara, n, bk_params)
end


#=
 * result = LWE(mu) iff phase(x)>0, LWE(-mu) iff phase(x)<0
 * @param result The resulting LweSample
 * @param bk The bootstrapping + keyswitch key
 * @param mu The output message (if phase(x)>0)
 * @param x The input sample
=#
function tfhe_bootstrap_FFT(result::LweSample,
                               bk::LweBootstrappingKeyFFT,
                               mu::Torus32,
                               x::LweSample)

    u = LweSample(bk.accum_params.extracted_lweparams)

    tfhe_bootstrap_woKS_FFT(u, bk, mu, x)

    # Key switching
    lweKeySwitch(result, bk.ks, u)

end
