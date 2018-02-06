__precompile__()

module FluxExtensions

using Flux
using ForwardDiff
using CoordinateTransformations

activation(σ) = x -> σ.(x)

plain(layer::Dense) = activation(layer.σ) ∘ AffineMap(Flux.Tracker.value(layer.W), Flux.Tracker.value(layer.b))
plain(t::Transformation) = t
plain(f::Function) = f
plain(chain::Chain) = reduce(∘, identity, plain.(reverse(chain.layers)))

struct TangentPropagator{F <: Function, C}
    f::F
    layer::C
end

function TangentPropagator(chain::Chain)
    f = reduce(∘, identity, _propagate_tangent.(reverse(chain.layers)))
    TangentPropagator(x -> f((x, eye(length(x)))), chain)
end

(p::TangentPropagator)(x) = p.f(x)

Flux.params(p::TangentPropagator) = Flux.params(p.layer)

function _propagate_tangent(f)
    (xJ) -> begin
        (f(xJ[1]), ForwardDiff.jacobian(f, Flux.Tracker.value(xJ[1])) * xJ[2])
    end
end

function _propagate_tangent(f::Dense)
    xJ -> begin
        x, J = xJ
        y = f.W * x + f.b
        gσ = ForwardDiff.derivative.(f.σ, y)
        (f(x), gσ .* f.W * J)
    end
end

struct Attention{T1, T2}
    signals::T1
    weights::T2
end

function (a::Attention)(x)
    sum(a.weights(x) .* a.signals(x), 1)
end

Flux.params(a::Attention) = vcat(params(a.signals), params(a.weights))

function TangentPropagator(a::Attention)
    t1 = TangentPropagator(a.signals)
    t2 = TangentPropagator(a.weights)
    function f(x)
        x1, J1 = t1(x)
        x2, J2 = t2(x)
        sum(x1 .* x2), sum(x1 .* J2, 1) .+ sum(x2 .* J1, 1)
    end
    TangentPropagator(f, a)
end

TangentPropagator(d::Dense) = TangentPropagator(Chain(d))

module FluxExtensionsTests
    using FluxExtensions
    using Flux
    using ForwardDiff
    using Flux.Tracker: value
    using CoordinateTransformations
    using Base.Test

    @testset "Flux extensions" begin
        srand(1)
        models = [
            Chain(
                AffineMap(randn(1, 1), randn(1)),
                Dense(1, 1, elu),
                Dense(1, 1, elu),
            ),
            Chain(
                Dense(1, 10, elu),
                Dense(10, 1, elu),
                AffineMap(randn(1, 1), randn(1)),
            ),
            Chain(
                Dense(1, 10, elu),
                AffineMap(randn(10, 10), randn(10)),
                Dense(10, 1, elu),
            ),
        ]
        for m in models
            mp = FluxExtensions.TangentPropagator(m)
            p = FluxExtensions.plain(m)

            for i in 1:100
                x = randn(1)
                y = m(x)
                y2, J = mp(x)
                @test value(y) ≈ value(y2)
                @test p(x) ≈ value(y)
                @test value(J) ≈ ForwardDiff.jacobian(p, x)
            end

            lf = (x, y, J) -> begin
                ŷ, Ĵ = mp(x)
                Flux.mse(ŷ, y) + Flux.mse(Ĵ, J)
            end
            train_data = [
                ([1.0], [1.2], [1.5])
            ]
            opt = Flux.Optimise.Momentum(params(mp))
            for i in 1:1000
                Flux.train!(lf, train_data, opt)
            end
            ŷ, Ĵ = mp([1.0])
            @test value(ŷ) ≈ [1.2]
            @test value(Ĵ) ≈ [1.5]

        end
    end
end
    

end
