# Categorical distribution that works with arbitrary objects (Rather than consecutive ints)
struct ObjectCategorical
    cat::Categorical
    objs
    ObjectCategorical(objs::T) where {T <: AbstractArray} = new(Categorical(length(objs)), objs)
    ObjectCategorical(objs::T) where {T <: Tuple} = new(Categorical(length(objs)), [objs...])
end

Base.rand(d::ObjectCategorical, sz::Int...) = d.objs[rand(d.cat, sz...)]
function Distributions.logpdf(d::ObjectCategorical, x)
    if x isa AbstractArray
        x = mapslices(findfirst, d.objs .== reshape(x, 1,:), dims=1)
        return logpdf.(d.cat, x)
    else
        x = findfirst(d.objs .== x)
        return logpdf(d.cat, x)
    end
    
end

# Constant Layer
struct ConstantLayer{T}
    vec::T
end

Flux.@functor ConstantLayer
(m::ConstantLayer)(x::AbstractArray) = m.vec



## Useful functions
whiten(v) = whiten(v, mean(v), std(v))
whiten(v, μ, σ) = (v .- μ) ./ σ

to2D(W) = reshape(W, :, size(W, ndims(W))) # convert a multidimensional weight matrix to 2D

# Weighted mean aggregator
weighted_mean(weights) = (y) -> mean(y .* weights)
    
function LinearAlgebra.norm(grads::Flux.Zygote.Grads; p::Real = 2)
    v = []
    for θ in grads.params
        !isnothing(grads[θ]) && push!(v, norm(grads[θ] |> cpu, p))
    end
    norm(v, p)
end

## Early stopping
# Early stopping function that terminates training on validation error increase
function stop_on_validation_increase(π, 𝒫, 𝒟_val, loss; window=5)
    k = "validation_error"
    (infos) -> begin
        ve = loss(π, 𝒫, 𝒟_val) # Compute the validation error
        infos[end][k] = ve # store it
        N = length(infos)
        if length(infos) >= 2*window
            curr_window = mean([infos[i][k] for i=N-window+1:N])
            old_window = mean([infos[i][k] for i=N-2*window+1:N-window])
            return curr_window >= old_window # check if the error has gone up
        end
        false
    end
end


## Losses
function td_loss(;loss=Flux.mse, name=:Qavg, s_key=:s, a_key=:a, weight=nothing)
    (π, 𝒫, 𝒟, y; info=Dict()) -> begin
        Q = value(π, 𝒟[s_key], 𝒟[a_key]) 
        
        # Store useful information
        ignore() do
            info[name] = mean(Q)
        end
        
        loss(Q, y, agg = isnothing(weight) ? mean : weighted_mean(𝒟[weight]))
    end
end

function double_Q_loss(;name1=:Q1avg, name2=:Q2avg, kwargs...)
    l1 = td_loss(;name=name1, kwargs...)
    l2 = td_loss(;name=name2, kwargs...)
    
    (π, 𝒫, 𝒟, y; info=Dict()) -> begin
        .5f0*(l1(π.C.N1, 𝒫, 𝒟, y, info=info) + l2(π.C.N2, 𝒫, 𝒟, y, info=info))
    end
end

td_error(π, 𝒟, y) = abs.(value(π, 𝒟[:s], 𝒟[:a])  .- y)


## Scheduling
struct LinearDecaySchedule{R<:Real} <: Function
    start::R
    stop::R
    steps::Int
end

function (schedule::LinearDecaySchedule)(i)
    rate = (schedule.start - schedule.stop) / schedule.steps
    val = schedule.start - i*rate 
    val = max(schedule.stop, val)
end

function MultitaskDecaySchedule(steps::Int, task_ids; start = 1.0, stop = 0.1)
    schedule = LinearDecaySchedule(start, stop, steps)
    function val(i)
        taskindex = ceil(Int, i / steps)
        taskindex < 1 && return start
        taskindex > length(task_ids) && return stop
        taskid = task_ids[taskindex]
        used_steps = steps*sum(task_ids[1:taskindex-1] .== taskid)
        schedule(used_steps + mod1(i, steps))
    end
end
