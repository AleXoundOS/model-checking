{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use camelCase" #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use camelCase" #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use camelCase" #-}
In this post, we'll talk about how to convert an imperative computer program
into a transition system. We'll then look at an example program, and show how to
use this conversion routine to check interesting invariants about the program's
behavior.

Preamble:

> module ModelChecking2 where
>
> import ModelChecking1
> import Data.Map.Strict (Map, (!), fromList, adjust, insert)

Program Graphs
==============

Our first task will be to define a very simple imperative programming language.
Our program representation will consist of a set of *locations*, which can be
thought of (roughly) as a line of code in a language like C. With each such
location, we associate a collection of *guarded transitions*. A guarded
transition is a triple `(guard, action, loc)`. If `guard` is true of the current
global state, then modify the state by performing `action` and go to location
`loc`." When a guard is satisified in a given state, the corresponding
transition is said to be *enabled*. When multiple transitions are enabled, one
of them is chosen nondeterministically.

We will call this construction a *program graph*. To define it in Haskell, we
first define a couple auxiliary notions.

The *state* of a program is a mapping from variables to values.

> type State var val = Map var val

A *state condition* is a predicate over the `State`.

> type StatePredicate var val = Predicate (State var val)

An *effect* is a state transformation, which modifies the state in some way.

> type Effect var val = State var val -> State var val

Finally, a *program graph* is defined by a set of guarded transitions, a set of
initial locations, and an initial state.

> data ProgramGraph loc action var val = ProgramGraph
>   { pgTransitions :: loc -> [(StatePredicate var val, action, loc)]
>   , pgEffect :: action -> Effect var val
>   , pgInitialLocations :: [loc]
>   , pgInitialState :: State var val
>   }

The `action` type is a name for each effect, and the `pgEffect` field maps each
action to its corresponding `Effect`.

Example: Soda Machine
=====================

Let's write a program that simulates a soda machine. The machine contains two
types of drinks: soda, and beer. Each of them costs a single coin.

There are three variables in our program: the number of coins in the machine,
the number of sodas in the machine, and the number of beers in the machine. We
have two locations in our program: `Start` and `Select`. In `Start`, the machine
is idle, waiting for a customer to insert a coin, or for a technician to collect
the coins and refill the beverages. In `Select`, the customer has inserted a
coin, and the machine can either dispense a soda or a beer. Alternatively, the
customer may push the "Return Coin" button, and his coin is returned to him.

Before defining the soda machine program graph, we first introduce a few
functions that will make the process feel a bit more like writing imperative
code. The following operators are convenient for constructing state conditions:

> unconditionally :: StatePredicate var val
> unconditionally = const True
>
> (!==) :: (Ord var, Eq val) => var -> val -> StatePredicate var val
> (var !== val) state = state ! var == val
> infix 4 !==
>
> (!>) :: (Ord var, Ord val) => var -> val -> StatePredicate var val
> (var !> val) state = state ! var > val
> infix 4 !>
>
> (!<) :: (Ord var, Ord val) => var -> val -> StatePredicate var val
> (var !< val) state = state ! var < val
> infix 4 !<

And the following operators are convenient for constructing effects:

> (=:) :: Ord var => var -> val -> Effect var val
> (=:) = insert
> infix 2 =:
>
> (+=:) :: (Ord var, Num val) => var -> val -> Effect var val
> var +=: val = adjust (+val) var
> infix 2 +=:
>
> (-=:) :: (Ord var, Num val) => var -> val -> Effect var val
> var -=: val = adjust (subtract val) var
> infix 2 -=:
>
> reset :: State var val -> Effect var val
> reset = const

Now, let's create a program graph representing the soda machine. First we will
define our set of variables, locations, and actions:

> data SodaMachineVar = NumCoins | NumSodas | NumBeers
>   deriving (Show, Eq, Ord)

> data SodaMachineLoc = Start | Select
>   deriving (Show, Eq, Ord)

> data SodaMachineAction = InsertCoin
>                        | GetBeer
>                        | GetSoda
>                        | ReturnCoin
>                        | ServiceMachine
>   deriving (Show, Eq, Ord)

Since all the variables are integer-valued, we can use `Int` as the value type
for our program graph.

> soda_machine :: Int -> Int -> ProgramGraph SodaMachineLoc SodaMachineAction SodaMachineVar Int
> soda_machine max_sodas max_beers =
>   let initial = fromList [ (NumCoins, 0)
>                          , (NumSodas, max_sodas)
>                          , (NumBeers, max_beers) ]
>   in ProgramGraph
>   { pgTransitions = \loc -> case loc of

The `Start` location has two outgoing guarded transitions. If the customer
inserts a coin, we transition to the `Select` location and increment the number
of coins in the machine. If the technician services the machine, we return the
machine to the initial state, setting the number of coins to `0` and filling the
beers and sodas to the maximum capacity.

>       Start -> [ ( unconditionally, InsertCoin    , Select )
>                , ( unconditionally, ServiceMachine, Start  ) ]

In the `Select` location, the customer has already inserted a coin, and is
selecting a drink. If the number of sodas is positive, then the customer can
select a soda, at which point the number of sodas is decremented and the machine
goes to location `Start`. The same holds for beer. Also, the user may press the
"Return Coin" button after inserting a coin, at which point the machine
unconditionally returns the coin.

>       Select -> [ ( NumSodas !> 0  , GetSoda   , Start )
>                 , ( NumBeers !> 0  , GetBeer   , Start )
>                 , ( unconditionally, ReturnCoin, Start ) ]

Now, for each action, we define the effect it has on the program state:

>   , pgEffect = \action -> case action of
>       InsertCoin     -> NumCoins +=: 1
>       GetSoda        -> NumSodas -=: 1
>       GetBeer        -> NumBeers -=: 1
>       ReturnCoin     -> NumCoins -=: 1
>       ServiceMachine -> reset initial

The machine starts in location `Start`, and is initially full of both soda and
beer.

>   , pgInitialLocations = [Start]
>   , pgInitialState = initial
>   }

Program Graphs to Transition Systems
====================================

We'd like to check properties of imperative programs using the machinery
developed in the previous post. First, though, we'll need to write a function
that converts a program graph to a transition system.

> pgToTS :: Eq loc
>        => ProgramGraph loc action var val
>        -> TransitionSystem (loc, State var val) action (Either loc (StatePredicate var val))

For a program graph with locations `loc`, variables `var`, and values `val`, the
states of the corresponding transition system will be pairs `(loc, State var
val)`. In other words, the state of the transition system has two parts: 1)
where we are in the program (the `loc`ation), and 2) what the concrete `State`s
of the global variables are.

The set of atomic propositions will consist of which location we are currently
in, as well as the set of all guards we could possibly define over the current
state. This will allow us to state a very broad class of properties to check.

Let's walk through the definition of `pgToTS`.

> pgToTS pg = TransitionSystem

The initial states of the transition system will be all pairs `(loc, state0)`
where `l` is an initial location of the program graph, and `state0` is the
initial state of the program graph.

>   { tsInitialStates = [ (loc, pgInitialState pg)
>                       | loc <- pgInitialLocations pg ]

Each `(loc, state)` pair is is labeled with the proposition that is `True` for
location `loc` and no other locations, and is also `True` for all state
conditions that are satisfied by `state`.

>   , tsLabel = \(loc, state) c -> case c of
>       Left loc' -> loc == loc'
>       Right cond -> cond state

Given a state `(loc, state)` in our transition system, we have an outgoing
transition for every transition in the program graph from `loc` whose guard is
satisfied by `state`.

>   , tsTransitions = \(loc, state) ->
>       [ (action, (loc', pgEffect pg action state))
>       | (guard, action, loc') <- pgTransitions pg loc
>       , guard state ]
>   }

We can use this conversion function to check properties of our soda machine
program.

Checking soda machine invariants
================================

One property we would like our soda machine to have is that the number of coins
is consistent with the current number of sodas and beers in the machine. In
particular, we would like to know that the number of coins, the number of sodas,
and the number of beers all add up to a constant number: `max_sodas +
max_beers`.

> soda_machine_invariant_1 :: Int -> Int -> Proposition (Either SodaMachineLoc (StatePredicate SodaMachineVar Int))
> soda_machine_invariant_1 max_sodas max_beers =
>   atom (Right (\state ->
>     state ! NumCoins + state ! NumSodas + state ! NumBeers ==
>     max_sodas + max_beers))

Let's check this property of our soda machine in ghci! We'll use a maximum
capacity of `2` for both soda and beer:

```{.haskell}
  > checkInvariant (soda_machine_invariant_1 2 2) (pgToTS (soda_machine 2 2))
  Just [(Start,fromList [(NumCoins,0),(NumSodas,2),(NumBeers,2)]),(Select,fromList [(NumCoins,1),(NumSodas,2),(NumBeers,2)])]
```

Aha! Our stated property actually doesn't hold. Immediately after the customer
inserts a coin, the system is in an inconsistent state. We can fix this by
restricting the invariant so it only applies when we are in the `Start` state:

> soda_machine_invariant_2 :: Int -> Int -> Proposition (Either SodaMachineLoc (StatePredicate SodaMachineVar Int))
> soda_machine_invariant_2 max_sodas max_beers =
>   atom (Left Start) .-> soda_machine_invariant_1 max_sodas max_beers

Now, let's check this new version:

```{.haskell}
  > checkInvariant (soda_machine_invariant_2 2 2) (pgToTS (soda_machine 2 2))
  Nothing
```

Wonderful! Now we know that whenever the machine is in the `Start` state, the
number of coins is equal to the number of sodas and beers that were purchased.

Conclusion
==========

In this post, we explored how to convert a higher-level imperative "program
graph", with a global state and guarded transitions, can be "compiled" or
"reified" into a transition system. We walked through an example program graph
representing a soda machine, converted this graph to a transition system, and
checked an invariant of that system to show that our machine has a nice property.

In the next post, we'll explore how a few techniques for modeling concurrent
processes.
