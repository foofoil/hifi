#include "All.h"
#include "Interim.h"

template int APE::CNNFilter<int, short>::DecompressGenericInterim(int nInput);
template APE::int64 APE::CNNFilter<APE::int64, int>::DecompressGenericInterim(APE::int64 nInput);

namespace APE
{

/**************************************************************************************************
DecompressGenericInterim
**************************************************************************************************/
template <class INTTYPE, class DATATYPE> INTTYPE APE::CNNFilter<INTTYPE, DATATYPE>::DecompressGenericInterim(INTTYPE nInput)
{
    // figure a dot product
    INTTYPE nDotProduct = APE::CalculateDotProductGeneric(&m_rbInput[-m_nOrder], &m_paryM[0], m_nOrder);

    // calculate the output
    INTTYPE nOutput;
    nOutput = static_cast<INTTYPE>(nInput + ((static_cast<int64>(nDotProduct) + m_nOneShiftedByShift) >> m_nShift));

    // adapt
    APE::AdaptGeneric(&m_paryM[0], &m_rbDeltaM[-m_nOrder], nInput, m_nOrder);

    // update delta
    UPDATE_DELTA_NEW(nOutput)

        // update the input buffer
        m_rbInput[0] = GetSaturatedShortFromInt(nOutput);

    // increment and roll if necessary
    m_rbInput.IncrementSafe();
    m_rbDeltaM.IncrementSafe();

    return nOutput;
}

}