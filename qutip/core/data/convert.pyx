#cython: language_level=3

"""
The conversion machinery between different data-layer types, and creation
routines from arbitrary data.  The classes `_to` and `_create` are not intended
to be exported names, but are the backing machinery of the functions `data.to`
and `data.create`, which are built up as the last objects in the `__init__.py`
initialisation of the `data` module.
"""

# This module is compiled by Cython because it's the core of the entire
# dispatch table, and having it compiled to a C extension saves about 1µs per
# call.  This is not much at all, and there's very little which benefits from
# Cython compiliation, but such core functionality is called millions of times
# even in a simple interactive QuTiP session, and it all adds up.

import numbers

import numpy as np
from scipy.sparse import dok_matrix, csgraph

cimport cython

__all__ = ['to', 'create']


def _raise_if_unconnected(dtype_list, weights):
    unconnected = {}
    for i, type_ in enumerate(dtype_list):
        missing = [dtype_list[j].__name__
                   for j, weight in enumerate(weights[:, i])
                   if weight == np.inf]
        if missing:
            unconnected[type_.__name__] = missing
    if unconnected:
        message = "Conversion graph not connected.  Cannot reach:\n * "
        message += "\n * ".join(to + " from (" + ", ".join(froms) + ")"
                                for to, froms in unconnected.items())
        raise NotImplementedError(message)


cdef class _converter:
    """Callable which converts objects of type `x.from_` to type `x.to`."""

    cdef list functions
    cdef Py_ssize_t n_functions
    cdef readonly type to
    cdef readonly type from_

    def __init__(self, functions, to_type, from_type):
        self.functions = list(functions)
        self.n_functions = len(self.functions)
        self.to = to_type
        self.from_ = from_type

    @cython.boundscheck(False)
    @cython.wraparound(False)
    def __call__(self, arg):
        if not isinstance(arg, self.from_):
            raise TypeError(str(arg) + " is not of type " + str(self.from_))
        cdef Py_ssize_t i
        for i in range(self.n_functions):
            arg = self.functions[i](arg)
        return arg

    def __repr__(self):
        return ("<converter to "
                + self.to.__name__
                + " from " + self.from_.__name__
                + ">")


cdef class _partial_converter:
    """Convert from any known data-layer type into the type `x.to`."""

    cdef dict converters
    cdef readonly type to

    def __init__(self, converters, to_type):
        self.converters = dict(converters)
        self.to = to_type

    def __call__(self, arg):
        try:
            return self.converters[type(arg)](arg)
        except KeyError:
            raise TypeError("unknown type of input: " + str(arg)) from None

    def __repr__(self):
        return "<converter to " + self.to.__name__ + ">"


# While `_to` and `_create` are defined as objects here, they are actually
# exported by `data.__init__.py` as singleton function objects of their
# respective types (without the leading underscore).

cdef class _to:
    """
    Convert data into a different type.  This object is the knowledge source
    for every allowable data-layer type in QuTiP, and provides the conversions
    between all of them.

    The base use is to call this object as a function with signature
        (type, data) -> converted_data
    where `type` is a type object (such as `data.CSR`, or that obtained by
    calling `type(matrix)`) and `data` is data in a data-layer type.  If you
    want to create a data-layer type from non-data-layer data, use `create`
    instead.

    You can get individual converters by using the key-lookup syntax.  For
    example, the item
        to[CSR, Dense]
    is a callable which accepts arguments of type `Dense` and returns the
    equivalent item of type `CSR`.  You can also get a generic converter to a
    particular data type if only one type is specified, so
        to[Dense]
    is a callable which accepts all known (at the time of the lookup)
    data-layer types, and converts them to `Dense`.  See the `Efficiency notes`
    section below for more detail.

    Internally, the conversion process may go through several steps if new
    data-layer types have been defined with few conversions specified between
    them and the pre-existing converters.  The first-class QuTiP data types
    `Dense` and `CSR` will typically have the best connectivity.


    Adding new types
    ----------------
    You can add new data-layer types by calling the `add_conversions` method of
    this object, and then rebuilding all of the mathematical dispatchers.  See
    the docstring of that method for more information.


    Efficiency notes
    ----------------
    From an efficiency perspective, there is very little benefit to using the
    key-lookup syntax.  Internally, `to(to_type, data)` effectively calls
    `to[to_type, type(data)]`, so storing the object elides the creation of a
    single tuple and a dict lookup, but the cost of this is generally less than
    500ns.  Using the one-argument lookup (e.g. `to[Dense]`) is no more
    efficient than the general call at all, but can be used in cases where a
    single callable is required and is more efficient than `functools.partial`.
    """

    cdef readonly set dtypes
    cdef readonly list dispatchers
    cdef dict _direct_convert
    cdef dict _convert
    cdef readonly dict weight

    def __init__(self):
        self._direct_convert = {}
        self._convert = {}
        self.dtypes = set()
        self.weight = {}
        self.dispatchers = []

    def add_conversions(self, converters):
        """
        Add conversion functions between different data types.  This is an
        advanced function, and is only intended for the QuTiP user who wants to
        add a new underlying data type to QuTiP.

        Any new data type must have at least one converter function given to
        produce the new data type from an existing data type, and at least one
        which produces an existing data type from the new one.  You need not
        specify any more than this, although for efficiency reasons, you may
        want to specify direct conversions for all types you expect the new
        type to interact with frequently.

        Parameters
        ----------
        converters : iterable of (to_type, from_type, converter, [weight])
            An iterable of 3- or 4-tuples describing all the new conversions.
            Each element can individually be a 3- or 4-tuple; they do not need
            to be all one or the other.

            Elements
            ........
            to_type : type
                The data-layer type that is output by the converter.

            from_type : type
                The data-layer type to be input to the converter.

            converter : callable (Data -> Data)
                The converter function.  This should take a single argument
                (the input data-layer function) and output a data-layer object
                of `to_type`.  The converter may assume without error checking
                that its input will always be of `to_type`.  It is safe to
                specify the same conversion function for multiple inputs so
                long as the function handles them all safely, but it must
                always return a single output type.

            weight : positive real, optional (1)
                The weight associated with this conversion.  This must be > 0,
                and defaults to `1` if not supplied (which is fixed to be the
                cost of conversion to `Dense` from `CSR`).  It is generally
                safe just to leave this blank; it is always at best an
                approximation.  The currently defined weights are accessible in
                the `weights` attribute of this object.
        """
        for arg in converters:
            if len(arg) == 3:
                to_type, from_type, converter = arg
                weight = 1
            elif len(arg) == 4:
                to_type, from_type, converter, weight = arg
            else:
                raise TypeError("unknown converter specification: " + str(arg))
            if not isinstance(to_type, type):
                raise TypeError(repr(to_type) + " is not a type object")
            if not isinstance(from_type, type):
                raise TypeError(repr(from_type) + " is not a type object")
            if not isinstance(weight, numbers.Real) or weight <= 0:
                raise TypeError("weight " + repr(weight) + " is not valid")
            self.dtypes.add(from_type)
            self.dtypes.add(to_type)
            self._direct_convert[(to_type, from_type)] = (converter, weight)
        # Two-way mapping to convert between the type of a dtype and an integer
        # enumeration value for it.
        order, index = [], {}
        for i, dtype in enumerate(self.dtypes):
            order.append(dtype)
            index[dtype] = i
        # Treat the conversion problem as a shortest-path graph problem.  We
        # build up the graph description as a matrix, then solve the
        # all-pairs-shortest-path problem.  We forbid negative weights and
        # there are unlikely to be many data types, so the choice of algorithm
        # is unimportant (Dijkstra's, Floyd--Warshall, Bellman--Ford, etc).
        graph = dok_matrix((len(order), len(order)))
        for (to_type, from_type), (_, weight) in self._direct_convert.items():
            graph[index[from_type], index[to_type]] = weight
        weights, predecessors =\
            csgraph.floyd_warshall(graph.tocsr(), return_predecessors=True)
        _raise_if_unconnected(order, weights)
        # Build the whole shortest path conversion lookup.  We directly store
        # all complete shortest paths, even though this is not the most memory
        # efficient, because we expect that there will generally be a small
        # number of available data types, and we care more about minimising the
        # number of lookups required.
        self.weight = {}
        self._convert = {}
        for i, from_t in enumerate(order):
            for j, to_t in enumerate(order):
                convert = []
                cur_t = to_t
                pred_i = predecessors[i, j]
                while pred_i >= 0:
                    pred_t = order[pred_i]
                    convert.append(self._direct_convert[(cur_t, pred_t)][0])
                    cur_t = pred_t
                    pred_i = predecessors[i, pred_i]
                self.weight[(to_t, from_t)] = len(convert)
                self._convert[(to_t, from_t)] =\
                    _converter(convert[::-1], to_t, from_t)
        for dispatcher in self.dispatchers:
            dispatcher.rebuild_lookup()

    @cython.boundscheck(False)
    @cython.wraparound(False)
    def __getitem__(self, arg):
        if isinstance(arg, type):
            arg = (arg,)
        if not isinstance(arg, tuple) or not arg or len(arg) > 2:
            raise KeyError(arg)
        to_t = arg[0]
        if to_t not in self.dtypes:
            raise TypeError("to_type is not known: " + str(to_t))
        if len(arg) == 1:
            converters = {
                from_t: self._convert[to_t, from_t] for from_t in self.dtypes
            }
            return _partial_converter(converters, to_t)
        from_t = arg[1]
        if from_t not in self.dtypes:
            raise TypeError("from_type is not known: " + str(from_t))
        return self._convert[to_t, from_t]

    def __call__(self, to_type, data):
        if not isinstance(to_type, type):
            raise TypeError(repr(to_type) + " is not a type object")
        if to_type not in self.dtypes:
            raise ValueError("unknown output type: " + to_type.__name__)
        from_type = type(data)
        if from_type not in self.dtypes:
            raise TypeError("unknown input type: " + from_type.__name__)
        if to_type == from_type:
            return data
        return self._convert[to_type, from_type](data)


cdef class _create:
    def __init__(self):
        pass

    def add_creators(self, creators):
        pass

    def __call__(self, arg, shape=None):
        from qutip.core.data import CSR, csr, dense
        import numpy as np
        import scipy.sparse
        if isinstance(arg, CSR):
            return arg.copy()
        if scipy.sparse.issparse(arg):
            return CSR(arg.tocsr(), shape=shape)
        # Promote 1D lists and arguments to kets, not bras by default.
        arr = np.array(arg, dtype=np.complex128)
        if arr.ndim == 1:
            arr = arr[:, np.newaxis]
        if arr.ndim != 2:
            raise TypeError("input has incorrect dimensions: " + str(arr.shape))
        return csr.from_dense(dense.fast_from_numpy(arr))


to = _to()
create = _create()