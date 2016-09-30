# cython: boundscheck=False, wraparound=False, cdivision=True
import numpy as np
import cPickle as pkl
import gzip
cimport cython
from cpython cimport array
import scipy.sparse as ssp
cimport numpy as np
from cython.parallel import prange
from libc.math cimport exp, log, fmax, fmin, sqrt
import multiprocessing

np.import_array()

cdef double inv_link_f(double e, int inv_link):
    if inv_link==1:  return 1.0 / (1.0 + exp(-fmax(fmin(e, 35.0), -35.0)))
    return e

cdef double predict_single(int* inds, double* vals, int lenn, double L1, double baL2, double alpha,
                double[:] w, double[:] z, double[:] n, bint bias_term, int threads) nogil:
    cdef int i, ii, lenn2= lenn
    cdef double sign, v, zi, wi
    cdef double e= 0.0
    if bias_term:  lenn2+= 1
    for ii in prange(lenn2, nogil=True, num_threads= threads):
        if ii!=lenn:
            i= inds[ii]
            v= vals[ii]
        else:
            i= 0
            v= 1.0
        zi= z[i]
        sign = -1.0 if zi < 0 else 1.0
        if sign * zi  > L1:
            wi= w[i] = (sign * L1 - zi) / (sqrt(n[i])/alpha + baL2)
            e+= wi * v
        else:  w[i] = 0.0
    return e

cdef void update_single(int* inds, double* vals, int lenn, double e, double alpha, double[:] w, double[:] z,
                        double[:] n, bint bias_term, int threads) nogil:
    cdef int i, ii, lenn2= lenn
    cdef double g, g2, v, ni
    if bias_term:  lenn2+= 1
    for ii in prange(lenn2, nogil=True, num_threads= threads):
        if ii!=lenn:
            i= inds[ii]
            v= vals[ii]
        else:
            i= 0
            v= 1.0
        g = e * v
        g2 = g * g
        ni= n[i]
        z[i] += g - ((sqrt(ni + g2) - sqrt(ni)) / alpha) * w[i]
        n[i] += g2

cdef class FTRL:
    cdef double[:] w
    cdef double[:] z
    cdef double[:] n

    cdef unsigned int threads
    cdef unsigned int iters
    cdef unsigned int D
    cdef double L1
    cdef double L2
    cdef double alpha
    cdef double beta
    cdef int inv_link
    cdef bint bias_term

    def __init__(self,
                 double alpha=0.1,
                 double beta=1.0,
                 double L1=1.0,
                 double L2=1.0,
                 unsigned int D=2**25,
                 unsigned int iters=1,
                 int threads= 0,
                 inv_link= "sigmoid",
                 bint bias_term=1):

        self.alpha= alpha
        self.beta= beta
        self.L1= L1
        self.L2= L2
        self.D= D
        self.iters= iters
        if threads==0:  threads= multiprocessing.cpu_count()-1
        self.threads= threads
        if inv_link=="sigmoid":  self.inv_link= 1
        if inv_link=="identity":  self.inv_link= 0
        self.bias_term= bias_term
        self.w= np.zeros((self.D,), dtype=np.float64)
        self.z= np.zeros((self.D,), dtype=np.float64)
        self.n= np.zeros((self.D,), dtype=np.float64)

    def predict(self, X, int threads= 0):
        if threads==0:  threads= self.threads
        if type(X) != ssp.csr.csr_matrix:  X= ssp.csr_matrix(X, dtype=np.float64)
        # return self.predict_f(X, np.ascontiguousarray(X.data), np.ascontiguousarray(X.indices),
        #               np.ascontiguousarray(X.indptr), threads)
        return self.predict_f(X.data, X.indices, X.indptr, threads)

    def predict_f(self, np.ndarray[double, ndim=1, mode='c'] X_data,
                    np.ndarray[int, ndim=1, mode='c'] X_indices,
                    np.ndarray[int, ndim=1, mode='c'] X_indptr, int threads):
        cdef double alpha= self.alpha, L1= self.L1
        p= np.zeros(X_indptr.shape[0]-1, dtype= np.float64)
        cdef double[:] w= self.w, z= self.z, n= self.n
        cdef double[:] pp= p
        cdef int lenn, row_count= X_indptr.shape[0]-1, row, ptr
        cdef bint bias_term= self.bias_term
        cdef int* inds2, indptr2
        cdef double* vals2
        cdef double baL2= self.beta/self.alpha+self.L2
        for row in range(row_count):
            ptr= X_indptr[row]
            lenn= X_indptr[row + 1] - ptr
            inds= <int*> X_indices.data + ptr
            vals= <double*> X_data.data + ptr
            pp[row]= inv_link_f(predict_single(inds, vals, lenn, L1, baL2, alpha, w, z, n,
                                               bias_term, threads), self.inv_link)
        return p

    def fit(self, X, y, int threads= 0):
        if threads == 0:  threads= self.threads
        if type(X) != ssp.csr.csr_matrix:  X = ssp.csr_matrix(X, dtype=np.float64)
        if type(y) != np.array:  y = np.array(y, dtype=np.float64)
        # self.fit_f(X, np.ascontiguousarray(X.data), np.ascontiguousarray(X.indices),
        #           np.ascontiguousarray(X.indptr), y, threads)
        self.fit_f(X.data, X.indices, X.indptr, y, threads)

    def fit_f(self, np.ndarray[double, ndim=1, mode='c'] X_data,
                    np.ndarray[int, ndim=1, mode='c'] X_indices,
                    np.ndarray[int, ndim=1, mode='c'] X_indptr, y, int threads):
        cdef double alpha= self.alpha, L1= self.L1
        cdef double[:] w= self.w, z= self.z, n= self.n, ys= y
        cdef int lenn, ptr, row_count= X_indptr.shape[0]-1, row
        cdef bint bias_term= self.bias_term
        cdef int* inds, indptr
        cdef double* vals
        cdef double baL2= self.beta/self.alpha+self.L2
        for iters in range(self.iters):
            for row in range(row_count):
                ptr= X_indptr[row]
                lenn= X_indptr[row+1]-ptr
                inds= <int*> X_indices.data+ptr
                vals= <double*> X_data.data+ptr
                update_single(inds, vals, lenn,
                              inv_link_f(predict_single(inds, vals, lenn, L1, baL2, alpha, w, z, n, bias_term,
                                                        threads),
                                         self.inv_link)-ys[row], alpha, w, z, n, bias_term, threads)

    def pickle_model(self, filename):
        with gzip.open(filename, 'wb') as model_file:
            pkl.dump(self.get_params(), model_file, protocol=2)

    def unpickle_model(self, filename):
        self.set_params(pkl.load(gzip.open(filename, 'rb')))

    def __getstate__(self):
        return (self.alpha, self.beta, self.L1, self.L2, self.D, self.iters,
                np.asarray(self.w), np.asarray(self.z), np.asarray(self.n), self.inv_link)

    def __setstate__(self, params):
        (self.alpha, self.beta, self.L1, self.L2, self.D, self.iters, self.w, self.z, self.n, self.inv_link)= params
