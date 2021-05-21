module AbstractDifferentiation

using LinearAlgebra, ExprTools

export AD

const AD = AbstractDifferentiation

abstract type AbstractBackend end
abstract type AbstractFiniteDifference <: AbstractBackend end
abstract type AbstractForwardMode <: AbstractBackend end
abstract type AbstractReverseMode <: AbstractBackend end

struct HigherOrderBackend{B} <: AbstractBackend
    backends::B
end
reduceorder(b::AbstractBackend) = b
function reduceorder(b::HigherOrderBackend)
    return HigherOrderBackend(reverse(Base.tail(reverse(b.backends))))
end
lowest(b::AbstractBackend) = b
lowest(b::HigherOrderBackend) = b.backends[end]
secondlowest(b::AbstractBackend) = b
secondlowest(b::HigherOrderBackend) = lowest(reduceorder(b))

# If the primal value is in y, extract it.
# Otherwise, re-compute it, e.g. in finite diff.
primalvalue(::AbstractFiniteDifference, ::Any, f, xs) = f(xs...)
primalvalue(::AbstractBackend, ys, ::Any, ::Any) = primalvalue(ys)
primalvalue(x::Tuple) = map(primalvalue, x)
primalvalue(x) = x

function derivative(ab::AbstractBackend, f, xs::Number...)
    der = getindex.(jacobian(lowest(ab), f, xs...), 1)
    if der isa Tuple
        return der
    else
        return (der,)
    end
end

function gradient(ab::AbstractBackend, f, xs...)
    return adjoint.(jacobian(lowest(ab), f, xs...))
end
function jacobian(ab::AbstractBackend, f, xs...) end
function hessian(ab::AbstractBackend, f, xs...)
    return jacobian(secondlowest(ab), (xs...,) -> begin
        gradient(lowest(ab), f, xs...)
    end, xs...)
end

function value_and_derivative(ab::AbstractBackend, f, xs::Number...)
    value, jacs = value_and_jacobian(lowest(ab), f, xs...)
    return value[1], getindex.(jacs, 1)
end
function value_and_gradient(ab::AbstractBackend, f, xs...)
    value, jacs = value_and_jacobian(lowest(ab), f, xs...)
    return value, adjoint.(jacs)
end
function value_and_jacobian(ab::AbstractBackend, f, xs...)
    local value
    primalcalled = false
    if lowest(ab) isa AbstractFiniteDifference
        value = primalvalue(ab, nothing, f, xs)
        primalcalled = true
    end
    jacs = jacobian(lowest(ab), (_xs...,) -> begin
        v = f(_xs...)
        if !primalcalled
            value = primalvalue(ab, v, f, xs)
            primalcalled = true
        end
        return v
    end, xs...)

    return value, jacs
end
function value_and_hessian(ab::AbstractBackend, f, xs...)
    local value
    primalcalled = false
    if ab isa AbstractFiniteDifference
        value = primalvalue(ab, nothing, f, xs)
        primalcalled = true
    end
    hess = jacobian(secondlowest(ab), (_xs...,) -> begin
        v, g = value_and_gradient(lowest(ab), f, _xs...)
        if !primalcalled
            value = primalvalue(ab, v, f, xs)
            primalcalled = true
        end
        return g
    end, xs...)
    return value, hess
end
function value_and_hessian(ab::HigherOrderBackend, f, xs...)
    local value
    primalcalled = false
    hess = jacobian(secondlowest(ab), (_xs...,) -> begin
        v, g = value_and_gradient(lowest(ab), f, _xs...)
        if !primalcalled
            value = primalvalue(ab, v, f, xs)
            primalcalled = true
        end
        return g
    end, xs...)
    return value, hess
end
function value_gradient_and_hessian(ab::AbstractBackend, f, xs...)
    local value
    primalcalled = false
    grads, hess = value_and_jacobian(secondlowest(ab), (_xs...,) -> begin
        v, g = value_and_gradient(lowest(ab), f, _xs...)
        if !primalcalled
            value = primalvalue(secondlowest(ab), v, f, xs)
            primalcalled = true
        end
        return g
    end, xs...)
    return value, grads, hess
end
function value_gradient_and_hessian(ab::HigherOrderBackend, f, xs...)
    local value
    primalcalled = false
    grads, hess = value_and_jacobian(secondlowest(ab), (_xs...,) -> begin
        v, g = value_and_gradient(lowest(ab), f, _xs...)
        if !primalcalled
            value = primalvalue(secondlowest(ab), v, f, xs)
            primalcalled = true
        end
        return g
    end, xs...)
    return value, grads, hess
end

function pushforward_function(
    ab::AbstractBackend,
    f,
    xs...,
)
    return (ds) -> begin
        return jacobian(lowest(ab), (xds...,) -> begin
            if ds isa Tuple
                @assert length(xs) == length(ds)
                newxs = xs .+ ds .* xds
                return f(newxs...)
            else
                @assert length(xs) == length(xds) == 1
                newx = xs[1] + ds * xds[1]
                return f(newx)
            end
        end, _zero.(xs, ds)...)
    end
end
function value_and_pushforward_function(
    ab::AbstractBackend,
    f,
    xs...,
)
    return (ds) -> begin
        @assert ds isa Tuple && length(ds) == length(xs)
        local value
        primalcalled = false
        if ab isa AbstractFiniteDifference
            value = primalvalue(ab, nothing, f, xs)
            primalcalled = true
        end
        pf = pushforward_function(lowest(ab), (_xs...,) -> begin
            vs = f(_xs...)
            if !primalcalled
                value = primalvalue(lowest(ab), vs, f, xs)
                primalcalled = true
            end
            return vs
        end, xs...)(ds)
        return value, pf
    end
end

_zero(::Number, d::Number) = zero(d)
_zero(::Number, d::AbstractVector) = zero(d)
_zero(::AbstractVector, d::AbstractVector) = zero(eltype(d))
_zero(::AbstractVector, d::AbstractMatrix) = zero(similar(d, size(d, 2)))
_zero(::AbstractMatrix, d::AbstractMatrix) = zero(d)
_zero(::Any, d::Any) = zero(d)

function pullback_function(ab::AbstractBackend, f, xs...)
    return (ws) -> begin
        jacs = jacobian(lowest(ab), (xs...,) -> begin
            vs = f(xs...)
            if ws isa Tuple
                @assert length(vs) == length(ws)
                return sum(zip(vs, ws)) do v, w
                    if w isa Union{AbstractMatrix, UniformScaling} && v isa AbstractVector
                        return w' * v
                    else
                        # for arbitrary arrays
                        return dot(w, v)
                    end
                end
            else
                w, v = ws, vs
                if w isa Union{AbstractMatrix, UniformScaling} && v isa AbstractVector
                    return w' * v
                else
                    # for arbitrary arrays
                    return dot(w, v)
                end
            end
        end, xs...)
        return adjoint.(jacs)
    end
end
function value_and_pullback_function(
    ab::AbstractBackend,
    f,
    xs...,
)
    return (ws) -> begin
        local value
        primalcalled = false
        if ab isa AbstractFiniteDifference
            value = primalvalue(ab, nothing, f, xs)
            primalcalled = true
        end
        if ws === nothing
            vs = f(xs...)
            if !primalcalled
                value = primalvalue(lowest(ab), vs, f, xs)
                primalcalled = true
            end
            return value, nothing
        end
        pb = pullback_function(lowest(ab), (_xs...,) -> begin
            vs = f(_xs...)
            if !primalcalled
                value = primalvalue(lowest(ab), vs, f, xs)
                primalcalled = true
            end
            return vs
        end, xs...)(ws)
        return value, pb
    end
end

struct LazyDerivative{B, F, X}
    backend::B
    f::F
    xs::X
end

function Base.:*(d::LazyDerivative, y)
    return derivative(d.backend, d.f, d.xs...) * y
end

function Base.:*(y, d::LazyDerivative)
    return y * derivative(d.backend, d.f, d.xs...)
end

function Base.:*(d::LazyDerivative, y::Union{Number,Tuple})
    return derivative(d.backend, d.f, d.xs...) .* y
end

function Base.:*(y::Union{Number,Tuple}, d::LazyDerivative)
    return y .* derivative(d.backend, d.f, d.xs...)
end

function Base.:*(d::LazyDerivative, y::AbstractArray)
    return map((d)-> d*y, derivative(d.backend, d.f, d.xs...))
end

function Base.:*(y::AbstractArray, d::LazyDerivative)
    return map((d)-> y*d, derivative(d.backend, d.f, d.xs...))
end


struct LazyGradient{B, F, X}
    backend::B
    f::F
    xs::X
end
Base.:*(d::LazyGradient, y) = gradient(d.ab, d.f, d.xs...) * y
Base.:*(y, d::LazyGradient) = y * gradient(d.ab, d.f, d.xs...)

struct LazyJacobian{B, F, X}
    backend::B
    f::F
    xs::X
end
function Base.:*(d::LazyJacobian, ys)
    return pushforward_function(d.ab, d.f, d.xs...)(ys)
end
function Base.:*(ys, d::LazyJacobian)
    if ys isa Tuple
        ya = adjoint.(ys)
    else
        ya = adjoint(ys)
    end
    return pullback_function(d.ab, d.f, d.xs...)(ya)
end

struct LazyHessian{B, F, X}
    backend::B
    f::F
    xs::X
end
function Base.:*(d::LazyHessian, ys)
    return pushforward_function(
        secondlowest(d.ab),
        (xs...,) -> gradient(lowest(d.ab), d.f, xs...),
        d.xs...,
    )(ys)
end
function Base.:*(ys, d::LazyHessian)
    if ys isa Tuple
        ya = adjoint.(ys)
    else
        ya = adjoint(ys)
    end
    return pullback_function(
        secondlowest(d.ab),
        (xs...,) -> gradient(lowest(d.ab), d.f, xs...),
        d.xs...,
    )(ya)
end

function lazyderivative(ab::AbstractBackend, f, xs::Number...)
    return LazyDerivative(ab, f, xs)
end
function lazygradient(ab::AbstractBackend, f, xs...)
    return LazyGradient(ab, f, xs)
end
function lazyhessian(ab::AbstractBackend, f, xs...)
    return LazyHessian(ab, f, xs)
end
function lazyjacobian(ab::AbstractBackend, f, xs...)
    return LazyJacobian(ab, f, xs)
end

struct D{B, F}
    backend::B
    f::F
end
D(b::AbstractBackend, d::D) = H(HigherOrderBackend((b, d.b)), d.f)
D(d::D) = H(HigherOrderBackend((d.backend, d.backend)), d.f)
function (d::D)(xs...; lazy = true)
    if lazy
        return lazyjacobian(d.ab, d.f, xs...)
    else
        return jacobian(d.ab, d.f, xs...)
    end
end

struct H{B, F}
    backend::B
    f::F
end
function (h::H)(xs...; lazy = true)
    if lazy
        return lazyhessian(h.ab, h.f, xs...)
    else
        return hessian(h.ab, h.f, xs...)
    end
end

macro primitive(expr)
    fdef = ExprTools.splitdef(expr)
    name = fdef[:name]
    if name == :pushforward_function
        return define_pushforward_function_and_friends(fdef) |> esc
    elseif name == :pullback_function
        return define_pullback_function_and_friends(fdef) |> esc
    elseif name == :jacobian
        return define_jacobian_and_friends(fdef) |> esc
    elseif name == :primalvalue
        return define_primalvalue(fdef) |> esc
    else
        throw("Unsupported AD primitive.")
    end
end

function define_pushforward_function_and_friends(fdef)
    fdef[:name] = :(AbstractDifferentiation.pushforward_function)
    args = fdef[:args]
    funcs = quote
        $(ExprTools.combinedef(fdef))
        function AbstractDifferentiation.jacobian($(args...),)
            identity_like = AbstractDifferentiation.identity_matrix_like($(args[3:end]...),)
            pff = AbstractDifferentiation.pushforward_function($(args...),)
            if eltype(identity_like) <: Tuple{Vararg{Union{AbstractMatrix, Number}}}
                return map(identity_like) do identity_like_i
                    return mapreduce(hcat, AbstractDifferentiation._eachcol.(identity_like_i)...) do (cols...)
                        pff(cols)
                    end
                end
            elseif eltype(identity_like) <: AbstractMatrix
                ret = hcat.(mapslices(identity_like[1], dims=1) do cols
                    pf = pff((cols,))
                    if typeof(pf) <: AbstractVector
                        return (pf, )
                    elseif typeof(pf) <: AbstractMatrix
                        return (transpose(pf), )
                    else
                        return pf
                    end
                end ...)
                return ret isa Tuple ? ret : (ret,)

            else
                return pff(identity_like)
            end
        end
    end
    return funcs
end

function define_pullback_function_and_friends(fdef)
    fdef[:name] = :(AbstractDifferentiation.pullback_function)
    args = fdef[:args]
    funcs = quote
        $(ExprTools.combinedef(fdef))
        function AbstractDifferentiation.jacobian($(args...),)
            value_and_pbf = AbstractDifferentiation.value_and_pullback_function($(args...),)
            value, _ = value_and_pbf(nothing)
            identity_like = AbstractDifferentiation.identity_matrix_like(value)
            if eltype(identity_like) <: Tuple{Vararg{AbstractMatrix}}
                return map(identity_like) do identity_like_i
                    return mapreduce(vcat, AbstractDifferentiation._eachcol.(identity_like_i)...) do (cols...)
                        value_and_pbf(cols)[2]'
                    end
                end
            elseif eltype(identity_like) <: AbstractMatrix
                return vcat.(mapslices(identity_like[1], dims=1) do cols
                    adjoint.(value_and_pbf((cols,))[2])
                end ...)
            else
                return adjoint.(value_and_pbf(identity_like)[2])
            end
        end
    end
    return funcs
end

_eachcol(a::Number) = (a,)
_eachcol(a) = eachcol(a)

function define_jacobian_and_friends(fdef)
    fdef[:name] = :(AbstractDifferentiation.jacobian)
    return ExprTools.combinedef(fdef)
end

function define_primalvalue(fdef)
    fdef[:name] = :(AbstractDifferentiation.primalvalue)
    return ExprTools.combinedef(fdef)
end

function identity_matrix_like(x)
    throw("The function `identity_matrix_like` is not defined for the type $(typeof(x)).")
end
function identity_matrix_like(x::AbstractVector)
    return (Matrix{eltype(x)}(I, length(x), length(x)),)
end
function identity_matrix_like(x::Number)
    return (one(x),)
end
identity_matrix_like(x::Tuple) = identity_matrix_like(x...)
@generated function identity_matrix_like(x...)
    expr = :(())
    for i in 1:length(x)
        push!(expr.args, :(()))
        for j in 1:i-1
            push!(expr.args[i].args, :((zero_matrix_like(x[$j])[1])))
        end
        push!(expr.args[i].args, :((identity_matrix_like(x[$i]))[1]))
        for j in i+1:length(x)
            push!(expr.args[i].args, :(zero_matrix_like(x[$j])[1]))
        end
    end
    return expr
end

zero_matrix_like(x::Tuple) = zero_matrix_like(x...)
zero_matrix_like(x...) = map(zero_matrix_like, x)
zero_matrix_like(x::AbstractVector) = (zero(similar(x, length(x), length(x))),)
zero_matrix_like(x::Number) = (zero(x),)
function zero_matrix_like(x)
    throw("The function `zero_matrix_like` is not defined for the type $(typeof(x)).")
end

end
