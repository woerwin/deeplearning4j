/*******************************************************************************
 * Copyright (c) 2019 Konduit K.K.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Apache License, Version 2.0 which is available at
 * https://www.apache.org/licenses/LICENSE-2.0.
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations
 * under the License.
 *
 * SPDX-License-Identifier: Apache-2.0
 ******************************************************************************/

//
//  @author sgazeos@gmail.com
//

#include <ops/declarable/helpers/random.h>
//#include <NativeOps.h>
#include <vector>
#include <memory>
#include <graph/Context.h>
#include <helpers/RandomLauncher.h>
#include <ShapeUtils.h>
#include <NDArrayFactory.h>
#include <cuda_exception.h>
#include <helpers/ConstantTadHelper.h>
#include <PointersManager.h>

namespace nd4j {
namespace ops {
namespace helpers {

    /*
     * fillGammaKernel - fill up output with gamma distributed values
     *
     *  uList - uniformly distributed values set
     *  uLength - length of uList
     *  alpha - alpha param
     *  beta - beta param
     *  output - distributed output.
     * */
    template <typename T>
    static __global__ void fillGammaKernel(T* uList, Nd4jLong uLength, T* alpha, Nd4jLong* alphaShape,
            T* beta, Nd4jLong* betaShape, T* output, Nd4jLong* outputShape) {
        // fill up
        __shared__ Nd4jLong aLength;
        if (threadIdx.x == 0) {
            aLength = shape::length(alphaShape);
        }
        __syncthreads();

        for (auto k = blockIdx.x; k < (int)uLength; k += gridDim.x) {
            auto pos = k * aLength;
            auto u = uList[k]; // this is a vector
            for (auto e = threadIdx.x; e < (int)aLength; e += blockDim.x) {
                auto aIndex = shape::getIndexOffset(e, alphaShape);
                auto bIndex = betaShape?shape::getIndexOffset(e, betaShape):-1LL;
                auto betaV = T(beta != nullptr ? beta[bIndex] * u : u);
                auto zIndex = shape::getIndexOffset(e + pos, outputShape);

                output[zIndex] = math::nd4j_igamma<T, T, T>(alpha[aIndex], betaV);
            }
        }
    }

    template <typename T>
    static void fillRandomGamma_(LaunchContext* context, graph::RandomGenerator& rng, NDArray* alpha, NDArray* beta, NDArray* output) {
        // To fill up output need to broadcast alpha and beta to the same shape and in
        Nd4jLong* broadcasted = nullptr;
        if (beta != nullptr)
            ShapeUtils::evalBroadcastShapeInfo(*alpha, *beta, true, broadcasted, context->getWorkspace());
        else
            broadcasted = alpha->shapeInfo();
        auto step = shape::length(broadcasted);
        auto shift = output->lengthOf() / step;

        auto copyAlpha = alpha;
        auto copyBeta = beta;
        if (beta != nullptr) {
            NDArray alphaBroadcasted(broadcasted, alpha->dataType(), true, context);
            NDArray betaBroadcasted(broadcasted, beta->dataType(), true, context);

            copyAlpha = new NDArray(alphaBroadcasted.applyTrueBroadcast(BroadcastOpsTuple::Assign(), *alpha));
            copyBeta = new NDArray(betaBroadcasted.applyTrueBroadcast(BroadcastOpsTuple::Assign(), *beta));
            copyAlpha->tickWriteDevice(); copyBeta->tickWriteDevice();
        }

        auto stream = context->getCudaStream();
        NDArray uniform = NDArrayFactory::create<T>('c', {shift}, context);
        uniform.syncToDevice();
        // fill up uniform with given length
        RandomLauncher::fillUniform(context, rng, &uniform, 0., 1.);

        fillGammaKernel<T><<<128, 128, 256, *stream>>>(uniform.dataBuffer()->specialAsT<T>(), shift,
                copyAlpha->dataBuffer()->specialAsT<T>(), copyAlpha->specialShapeInfo(),
                beta?copyBeta->dataBuffer()->specialAsT<T>():(T*)nullptr,
                beta?copyBeta->specialShapeInfo():(Nd4jLong*)nullptr,
                output->dataBuffer()->specialAsT<T>(), output->specialShapeInfo());

        if (beta != nullptr) {
            delete copyAlpha;
            delete copyBeta;
            //delete broadcasted;
        }

    }

    void fillRandomGamma(LaunchContext* context, graph::RandomGenerator& rng, NDArray* alpha, NDArray* beta, NDArray* output) {
        if (beta)
            NDArray::prepareSpecialUse({output}, {alpha, beta});
        else
            NDArray::prepareSpecialUse({output}, {alpha});
        BUILD_SINGLE_SELECTOR(output->dataType(), fillRandomGamma_, (context, rng, alpha, beta, output), FLOAT_NATIVE);
        if (beta)
            NDArray::registerSpecialUse({output}, {alpha, beta});
        else
            NDArray::prepareSpecialUse({output}, {alpha});
    }
    BUILD_SINGLE_TEMPLATE(template void fillRandomGamma_, (LaunchContext* context, graph::RandomGenerator& rng, NDArray* alpha, NDArray* beta, NDArray* output), FLOAT_NATIVE);


    /*
     * algorithm Poisson generator based upon the inversion by sequential search
     *
    init:
         Let x ← 0, p ← e−λ, s ← p.
         using uniformly random sequence U (u in U) distributed at [0, 1].
    while u > s do:
         x ← x + 1.
         p ← p * λ / x.
         s ← s + p.
    return x.
     * */
    template <typename T>
    static __global__ void fillPoissonKernel(T* uList, Nd4jLong uLength, T* lambda, Nd4jLong* lambdaShape, T* output,
            Nd4jLong* outputShape) {

        __shared__ Nd4jLong step;

        if (threadIdx.x == 0) {
            step = shape::length(lambdaShape);
        }
        __syncthreads();

        for (auto k = blockIdx.x; k < (int)uLength; k += gridDim.x) {
            auto pos = k * step;
            auto u = uList[k];
            for (auto e = threadIdx.x; e < step; e += blockDim.x) {
                auto p = math::nd4j_exp<T,T>(-lambda[e]);
                auto s = p;
                auto x = T(0.f);
                auto lIndex = shape::getIndexOffset(e, lambdaShape);
                auto zIndex = shape::getIndexOffset(e + pos, outputShape);
                while (u > s) {
                    x += T(1.);
                    p *= lambda[lIndex] / x;
                    s += p;
                }
                output[zIndex] = x;
            }
        }
    }

    template <typename T>
    static void fillRandomPoisson_(LaunchContext* context, graph::RandomGenerator& rng, NDArray* lambda, NDArray* output) {
        auto shift = output->lengthOf() / lambda->lengthOf();
        NDArray uniform('c', {shift}, output->dataType());
        auto stream = context->getCudaStream();
        // fill up uniform with given length
        RandomLauncher::fillUniform(context, rng, &uniform, 0., 1.);
        fillPoissonKernel<T><<<128, 256, 128, *stream>>>(uniform.dataBuffer()->specialAsT<T>(), uniform.lengthOf(),
                lambda->dataBuffer()->specialAsT<T>(), lambda->specialShapeInfo(),
                output->dataBuffer()->specialAsT<T>(), output->specialShapeInfo());
    }

    void fillRandomPoisson(LaunchContext* context, graph::RandomGenerator& rng, NDArray* lambda, NDArray* output) {
        NDArray::prepareSpecialUse({output}, {lambda});
        BUILD_SINGLE_SELECTOR(output->dataType(), fillRandomPoisson_, (context, rng, lambda, output), FLOAT_NATIVE);
        NDArray::registerSpecialUse({output}, {lambda});
    }

    BUILD_SINGLE_TEMPLATE(template void fillRandomPoisson_, (LaunchContext* context, graph::RandomGenerator& rng, NDArray* lambda, NDArray* output), FLOAT_NATIVE);

    template <typename T>
    static __global__ void fillUniformKernel(graph::RandomGenerator* devRng, T from, T to, T* output, Nd4jLong* outputShape) {
        auto start = blockIdx.x * blockDim.x + threadIdx.x;
        auto step = blockDim.x * gridDim.x;

        __shared__ Nd4jLong outputLen;

        if (0 == threadIdx.x) {
            outputLen = shape::length(outputShape);
        }
        __syncthreads();

        for (auto i = start; i < outputLen; i += step) {
            auto zIndex = shape::getIndexOffset(i, outputShape);
            output[zIndex] = devRng->relativeT<T>(i, from, to);
        }

    }

    template <typename T>
    static void fillRandomUniform_(LaunchContext* context, graph::RandomGenerator& rng, NDArray* min, NDArray* max, NDArray* output) {
        T minVal = T(0);
        T maxVal = DataTypeUtils::infOrMax<T>();
        if (min)
            minVal = min->t<T>(0);
        if (max)
            maxVal = max->t<T>(0);

        if (output->isR())
            RandomLauncher::fillUniform(context, rng, output, minVal, maxVal);
        else {
            auto stream = context->getCudaStream();
            graph::RandomGenerator *devRng;
            auto err = cudaMalloc(&devRng, sizeof(graph::RandomGenerator));
            if (err != 0) {
                cuda_exception::build("fillRandomUniform_: Cannot allocate device memory for random generator due error", err);
            }

            err = cudaMemcpy(devRng, &rng, sizeof(graph::RandomGenerator), cudaMemcpyHostToDevice);
            if (err != 0) {
                cuda_exception::build("fillRandomUniform_: Cannot copy random generator to device", err);
            }
            auto outputBuf = output->dataBuffer()->specialAsT<T>();
            auto outputShape = output->specialShapeInfo();
            fillUniformKernel<T><<<128, 128, 128, *stream>>>(devRng, minVal, maxVal, outputBuf, outputShape);

            err = cudaStreamSynchronize(*stream);
            if (err != 0) {
                cuda_exception::build("fillRandomUniform_: Cannot successfully finish kernel call", err);
            }

            err = cudaFree(devRng);
            if (err != 0) {
                cuda_exception::build("fillRandomUniform_: Cannot deallocate device memory for random generator", err);
            }
        }
    }

    void fillRandomUniform(LaunchContext* context, graph::RandomGenerator& rng, NDArray* min, NDArray* max, NDArray* output) {
        BUILD_SINGLE_SELECTOR(output->dataType(), fillRandomUniform_, (context, rng, min, max, output), NUMERIC_TYPES);
    }

    BUILD_SINGLE_TEMPLATE(template void fillRandomUniform_, (LaunchContext* context,
            graph::RandomGenerator& rng, NDArray* min, NDArray* max, NDArray* output), NUMERIC_TYPES);

///////////////////////////////////////////////////////////////////
// used https://en.wikipedia.org/wiki/Categorical_distribution
// methods: gumbel trick + softmax + argmax
template<typename X, typename Z>
__global__ static void fillMultiNomialCuda_(graph::RandomGenerator* devRng, const void* vx, const Nd4jLong* xShapeInfo, 
                                     void* vz, const Nd4jLong* zShapeInfo, const Nd4jLong batchValue, 
                                     const Nd4jLong numOfSamples, const Nd4jLong numOfClassX, 
                                     const Nd4jLong dimA, const X minVal, const X maxVal) {
                                  
    
    const X* x = reinterpret_cast<const X*>(vx);
    Z* z = reinterpret_cast<Z*>(vz);
   
    __shared__ Nd4jLong xDimAstride, zDimAstride, xDimCstride, zDimCstride, dimC;

    if (0 == threadIdx.x) {
        dimC = (0 == dimA) ? 1 : 0;
        zDimAstride = shape::stride(zShapeInfo)[dimA];
        xDimAstride = shape::stride(xShapeInfo)[dimA];
        zDimCstride = shape::stride(zShapeInfo)[dimC];
        xDimCstride = shape::stride(xShapeInfo)[dimC];
    }
    __syncthreads();

    const auto tid = blockIdx.x * blockDim.x + threadIdx.x;
    
    for (Nd4jLong index = tid; index < batchValue*numOfSamples; index += gridDim.x * blockDim.x) {
        
        Nd4jLong nBatchIndex = index / numOfSamples;
        Nd4jLong nSampleIndexInBatch = index - (nBatchIndex * numOfSamples);
        
        const X* xTad = x + (nBatchIndex * xDimCstride);
        Z* zTad = z + (nBatchIndex * zDimCstride);
        Z& arg = zTad[nSampleIndexInBatch * zDimAstride];
        
        X Max = -minVal;
        Nd4jLong nSamplesPerBatch = nBatchIndex * numOfClassX * numOfSamples;
        Nd4jLong nClassPerSamples = nSampleIndexInBatch * numOfClassX;
        
        for (Nd4jLong nClass = 0; nClass < numOfClassX; nClass++) {
            Nd4jLong nIndex = nSamplesPerBatch + nClassPerSamples + nClass;
            X tValue = (xTad[nClass * xDimAstride] - nd4j::math::nd4j_log<X, X>(-nd4j::math::nd4j_log<X, X>(devRng->relativeT<X>(nIndex, minVal, maxVal))));
            if (tValue > Max) {
                Max = tValue; 
                arg = nClass;
            }
        }
    }
}

//////////////////////////////////////////////////////////////////////////
template<typename X, typename Z>
__host__ static void fillMultiNomialCudaLauncher(
    const int blocksPerGrid, const int threadsPerBlock, const cudaStream_t* stream,
    graph::RandomGenerator* devRng, const void* vx, const Nd4jLong* xShapeInfo, 
    void* vz, const Nd4jLong* zShapeInfo, 
    const Nd4jLong batchValue, const Nd4jLong numOfSamples, 
    const Nd4jLong numOfClassX, const Nd4jLong dimA){

    const X minVal = DataTypeUtils::min<X>();
    const X maxVal = 1.0;
    
    fillMultiNomialCuda_<X, Z> <<< blocksPerGrid, threadsPerBlock, 256, * stream >>> (
        devRng, vx, xShapeInfo, vz, zShapeInfo, batchValue,
        numOfSamples, numOfClassX, dimA, minVal, maxVal);
}
 
///////////////////////////////////////////////////////////////////
void fillRandomMultiNomial(LaunchContext* context, graph::RandomGenerator& rng, NDArray& input, NDArray& output, const Nd4jLong numOfSamples, const int dimC) {

     Nd4jLong dimA = (0 == dimC) ? 1 : 0;

     const Nd4jLong batchValue = output.sizeAt(dimC);
     const Nd4jLong numOfClassX = input.sizeAt(dimA);
     
     const int threadsPerBlock = MAX_NUM_THREADS / 2;
     const int blocksPerGrid = (batchValue * numOfSamples + threadsPerBlock - 1) / threadsPerBlock;
    
     PointersManager manager(context, "fillMultinomial");
     graph::RandomGenerator *devRng;

     auto err = cudaMalloc(&devRng, sizeof(graph::RandomGenerator));
     if (err != 0) {
         cuda_exception::build("fillRandomMultiNomial: Cannot allocate device memory for random generator due error", err);
     }
     err = cudaStreamSynchronize(*context->getCudaStream());
     if (err != 0) {
         cuda_exception::build("fillRandomMultiNomial: Cannot synchronize stream for random generator due error", err);
     }
     err = cudaMemcpyAsync(devRng, &rng, sizeof(graph::RandomGenerator), cudaMemcpyHostToDevice, *context->getCudaStream());
     if (err != 0) {
         cuda_exception::build("fillRandomMultiNomial: Cannot copy random generator to device", err);
     }

     NDArray::prepareSpecialUse({ &output }, { &input });
     BUILD_DOUBLE_SELECTOR(input.dataType(), output.dataType(), fillMultiNomialCudaLauncher, 
      (blocksPerGrid, threadsPerBlock, context->getCudaStream(), devRng, input.getSpecialBuffer(), 
       input.getSpecialShapeInfo(), output.specialBuffer(), 
       output.specialShapeInfo(), batchValue, numOfSamples, 
       numOfClassX, dimA), FLOAT_TYPES, INDEXING_TYPES);
     NDArray::registerSpecialUse({ &output }, { &input });
     manager.synchronize();

     err = cudaFree(devRng);
     if (err != 0) {
         cuda_exception::build("fillRandomMultiNomial: Cannot deallocate device memory for random generator", err);
     }
     rng.rewindH(output.lengthOf() * numOfClassX);
 }

}
}
}