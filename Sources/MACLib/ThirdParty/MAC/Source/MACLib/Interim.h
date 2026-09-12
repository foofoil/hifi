#pragma once

/**************************************************************************************************
Interim mode is needed to decode 24-bit files encoded durning the short spell after adding
32-bit when encoding was unintentionally changed. The date range was November 5, 2019
(Monkey's Audio 5.01) to August 14, 2022 (Monkey's Audio 8.51).
**************************************************************************************************/

#include "NewPredictor.h"
#include "NNFilter.h"
#include "NNFilterCommon.h"

namespace APE
{

/**************************************************************************************************
CPredictorDecompressInterim
**************************************************************************************************/
class CPredictorDecompressInterim : public CPredictorDecompress3950toCurrent<int, short>
{
public:
    CPredictorDecompressInterim(int nCompressionLevel, APE_VERSION Version, int nBitsPerSample) :
        CPredictorDecompress3950toCurrent<int, short>(nCompressionLevel, Version, nBitsPerSample)
    {
    }
    virtual ~CPredictorDecompressInterim() APE_OVERRIDE
    {
    }

    int DecompressValue(int64 _nA, int64 _nB = 0) APE_OVERRIDE
    {
        if (m_nCurrentIndex == WINDOW_BLOCKS)
        {
            // copy forward and adjust pointers
            m_rbPredictionA.Roll(); m_rbPredictionB.Roll();
            m_rbAdaptA.Roll(); m_rbAdaptB.Roll();

            m_nCurrentIndex = 0;
        }

        int nA = static_cast<int>(_nA);
        int nB = static_cast<int>(_nB);

        // stage 2: NNFilter
        if (m_spNNFilter2)
            nA = m_spNNFilter2->Decompress(nA);
        if (m_spNNFilter1)
            nA = m_spNNFilter1->Decompress(nA);
        if (m_spNNFilter)
            nA = m_spNNFilter->Decompress(nA);

        // stage 1: multiple predictors (order 2 and offset 1)
        m_rbPredictionA[0] = m_nLastValueA;
        m_rbPredictionA[-1] = m_rbPredictionA[0] - m_rbPredictionA[-1];

        m_rbPredictionB[0] = m_Stage1FilterB.Compress(static_cast<int32>(nB));
        m_rbPredictionB[-1] = m_rbPredictionB[0] - m_rbPredictionB[-1];

        int nCurrentA;
        if ((m_nBitsPerSample <= 16) || (sizeof(int) == 8))
        {
            const int nPredictionA = (m_rbPredictionA[0] * m_aryMA[0]) + (m_rbPredictionA[-1] * m_aryMA[1]) + (m_rbPredictionA[-2] * m_aryMA[2]) + (m_rbPredictionA[-3] * m_aryMA[3]);
            const int nPredictionB = (m_rbPredictionB[0] * m_aryMB[0]) + (m_rbPredictionB[-1] * m_aryMB[1]) + (m_rbPredictionB[-2] * m_aryMB[2]) + (m_rbPredictionB[-3] * m_aryMB[3]) + (m_rbPredictionB[-4] * m_aryMB[4]);

            nCurrentA = nA + ((nPredictionA + (nPredictionB >> 1)) >> 10);
        }
        else
        {
            const int64 nPredictionA = (static_cast<int64>(m_rbPredictionA[0]) * m_aryMA[0]) + (static_cast<int64>(m_rbPredictionA[-1]) * m_aryMA[1]) + (static_cast<int64>(m_rbPredictionA[-2]) * m_aryMA[2]) + (static_cast<int64>(m_rbPredictionA[-3]) * m_aryMA[3]);
            const int64 nPredictionB = (static_cast<int64>(m_rbPredictionB[0]) * m_aryMB[0]) + (static_cast<int64>(m_rbPredictionB[-1]) * m_aryMB[1]) + (static_cast<int64>(m_rbPredictionB[-2]) * m_aryMB[2]) + (static_cast<int64>(m_rbPredictionB[-3]) * m_aryMB[3]) + (static_cast<int64>(m_rbPredictionB[-4]) * m_aryMB[4]);

            nCurrentA = nA + static_cast<int>((nPredictionA + (nPredictionB >> 1)) >> 10);
        }

        m_rbAdaptA[0] = (m_rbPredictionA[0]) ? ((m_rbPredictionA[0] >> 30) & 2) - 1 : 0;
        m_rbAdaptA[-1] = (m_rbPredictionA[-1]) ? ((m_rbPredictionA[-1] >> 30) & 2) - 1 : 0;

        m_rbAdaptB[0] = (m_rbPredictionB[0]) ? ((m_rbPredictionB[0] >> 30) & 2) - 1 : 0;
        m_rbAdaptB[-1] = (m_rbPredictionB[-1]) ? ((m_rbPredictionB[-1] >> 30) & 2) - 1 : 0;

        const int nDirection = ((nA < 0) - (nA > 0));
        m_aryMA[0] += m_rbAdaptA[0] * nDirection;
        m_aryMA[1] += m_rbAdaptA[-1] * nDirection;
        m_aryMA[2] += m_rbAdaptA[-2] * nDirection;
        m_aryMA[3] += m_rbAdaptA[-3] * nDirection;

        m_aryMB[0] += m_rbAdaptB[0] * nDirection;
        m_aryMB[1] += m_rbAdaptB[-1] * nDirection;
        m_aryMB[2] += m_rbAdaptB[-2] * nDirection;
        m_aryMB[3] += m_rbAdaptB[-3] * nDirection;
        m_aryMB[4] += m_rbAdaptB[-4] * nDirection;

        const int nResult = m_Stage1FilterA.Decompress(nCurrentA);
        m_nLastValueA = nCurrentA;

        m_rbPredictionA.IncrementFast(); m_rbPredictionB.IncrementFast();
        m_rbAdaptA.IncrementFast(); m_rbAdaptB.IncrementFast();

        m_nCurrentIndex++;

        return nResult;
    }
};

}

