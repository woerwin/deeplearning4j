/*******************************************************************************
 * Copyright (c) 2020 Konduit, K.K.
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
//  @author GS <sgazeos@gmail.com>
//
#include <op_boilerplate.h>
#include <NDArray.h>
#include <NDArrayFactory.h>
#include <execution/Threads.h>
#include <helpers/MmulHelper.h>

#include "../triangular_solve.h"
#include "../lup.h"
#include "../solve.h"

namespace nd4j {
namespace ops {
namespace helpers {

// --------------------------------------------------------------------------------------------------------------------------------------- //
    template <typename T>
    static void adjointMatrix_(nd4j::LaunchContext* context, NDArray const* input, NDArray* output) {
        auto inputPart = input->allTensorsAlongDimension({-2, -1});
        auto outputPart = output->allTensorsAlongDimension({-2, -1});
        auto rows = input->sizeAt(-2);
        output->assign(input);

        auto batchLoop = PRAGMA_THREADS_FOR {
            for (auto batch = start; batch < stop; batch++) {
                for (auto r = 0; r < rows; r++) {
                    for (auto c = 0; c < r; c++) {
                        math::nd4j_swap(outputPart[batch]->t<T>(r, c) , outputPart[batch]->t<T>(c, r));
                    }
                }
            }
        };
        samediff::Threads::parallel_tad(batchLoop, 0, inputPart.size(), 1);
    }

// --------------------------------------------------------------------------------------------------------------------------------------- //
    template <typename T>
    static int solveFunctor_(nd4j::LaunchContext * context, NDArray* leftInput, NDArray* rightInput, bool const adjoint, NDArray* output) {

        // stage 1: LU decomposition batched
        auto leftOutput = leftInput->ulike();
        auto permuShape = rightInput->getShapeAsVector(); permuShape.pop_back();
        auto permutations = NDArrayFactory::create<int>('c', permuShape, context);
        helpers::lu(context, leftInput, &leftOutput, &permutations);
        auto P = leftInput->ulike(); //permutations batched matrix
        P.nullify(); // to fill up matricies with zeros
        auto PPart = P.allTensorsAlongDimension({-2,-1});
        auto permutationsPart = permutations.allTensorsAlongDimension({-1});

        for (auto batch = 0; batch < permutationsPart.size(); ++batch) {
            for (auto row = 0; row < PPart[batch]->rows(); ++row) {
                PPart[batch]->t<T>(row, permutationsPart[batch]->t<int>(row)) = T(1.f);
            }
        }

        auto leftLower = leftOutput.dup();
        auto rightOutput = rightInput->ulike();
        auto rightPermuted = rightOutput.ulike();
        MmulHelper::matmul(&P, rightInput, &rightPermuted, 0, 0);
        ResultSet leftLowerPart = leftLower.allTensorsAlongDimension({-2, -1});
        for (auto i = 0; i < leftLowerPart.size(); i++) {
            for (auto r = 0; r < leftLowerPart[i]->rows(); r++)
                leftLowerPart[i]->t<T>(r,r) = (T)1.f;
        }
        // stage 2: triangularSolveFunctor for Lower with given b
        helpers::triangularSolveFunctor(context, &leftLower, &rightPermuted, true, false, &rightOutput);
        // stage 3: triangularSolveFunctor for Upper with output of previous stage
        helpers::triangularSolveFunctor(context, &leftOutput, &rightOutput, false, false, output);

        return Status::OK();
    }

// --------------------------------------------------------------------------------------------------------------------------------------- //
    int solveFunctor(nd4j::LaunchContext * context, NDArray* leftInput, NDArray* rightInput, bool const adjoint, NDArray* output) {
        BUILD_SINGLE_SELECTOR(leftInput->dataType(), return solveFunctor_, (context, leftInput, rightInput, adjoint, output), FLOAT_TYPES);
    }
// --------------------------------------------------------------------------------------------------------------------------------------- //
    void adjointMatrix(nd4j::LaunchContext* context, NDArray const* input, NDArray* output) {
        BUILD_SINGLE_SELECTOR(input->dataType(), adjointMatrix_, (context, input, output), FLOAT_TYPES);
    }
// --------------------------------------------------------------------------------------------------------------------------------------- //
}
}
}
