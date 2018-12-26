{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE FlexibleContexts #-}
module Main where

import qualified Data.HashMap.Strict as M
import Control.Monad (forM_, void)
import qualified Data.Vector.Storable as SV
import Control.Monad.IO.Class
import System.IO (hFlush, stdout)

import MXNet.Base (NDArray(..), contextCPU, contextGPU0, mxListAllOpNames, toVector, (.&), HMap(..), ArgOf(..))
import qualified MXNet.Base.Operators.NDArray as A
import MXNet.NN
import MXNet.NN.DataIter.Class
import MXNet.NN.DataIter.Conduit
import qualified Model.Lenet as Model

type ArrayF = NDArray Float
type DS = ConduitData (TrainM Float IO) (ArrayF, ArrayF)

range :: Int -> [Int]
range = enumFromTo 1

default_initializer :: Initializer Float
default_initializer name shp@[_]   = zeros name shp
default_initializer name shp@[_,_] = xavier 2.0 XavierGaussian XavierIn name shp
default_initializer name shp = normal 0.1 name shp
    
main :: IO ()
main = do
    -- call mxListAllOpNames can ensure the MXNet itself is properly initialized
    -- i.e. MXNet operators are registered in the NNVM
    _    <- mxListAllOpNames
    net  <- Model.symbol
    sess <- initialize net $ Config { 
                _cfg_placeholders = M.singleton "x" [1,1,28,28],
                _cfg_initializers = M.empty,
                _cfg_default_initializer = default_initializer,
                _cfg_context = contextGPU0
            }
    optimizer <- makeOptimizer SGD'Mom (Const 0.0002) Nil

    train sess $ do 

        let trainingData = mnistIter (#image := "dataiter/test/data/train-images-idx3-ubyte" .&
                                      #label := "dataiter/test/data/train-labels-idx1-ubyte" .& 
                                      #batch_size := 128 .& Nil)
        let testingData  = mnistIter (#image := "dataiter/test/data/t10k-images-idx3-ubyte" .&
                                      #label := "dataiter/test/data/t10k-labels-idx1-ubyte" .&
                                      #batch_size := 16  .& Nil)

        total1 <- sizeD trainingData
        liftIO $ putStrLn $ "[Train] "
        forM_ (range 1) $ \ind -> do
            liftIO $ putStrLn $ "iteration " ++ show ind
            metric <- mCE ["y"]
            void $ forEachD_i trainingData $ \(i, (x, y)) -> do
                fitAndEval optimizer (M.fromList [("x", x), ("y", y)]) metric
                eval <- format metric
                liftIO $ do
                   putStr $ "\r\ESC[K" ++ show i ++ "/" ++ show total1 ++ " " ++ eval
                   hFlush stdout
            liftIO $ putStrLn ""
        
        liftIO $ putStrLn $ "[Test] "

        total2 <- sizeD testingData
        result <- forEachD_i testingData $ \(i, (x, y)) -> do 
            liftIO $ do 
                putStr $ "\r\ESC[K" ++ show i ++ "/" ++ show total2
                hFlush stdout
            [y'] <- forwardOnly (M.fromList [("x", Just x), ("y", Nothing)])
            ind1 <- liftIO $ toVector y
            ind2 <- liftIO $ argmax y' >>= toVector
            return (ind1, ind2)
        liftIO $ putStr "\r\ESC[K"

        let (ls,ps) = unzip result
            ls_unbatched = mconcat ls
            ps_unbatched = mconcat ps
            total_test_items = SV.length ls_unbatched
            correct = SV.length $ SV.filter id $ SV.zipWith (==) ls_unbatched ps_unbatched
        liftIO $ putStrLn $ "Accuracy: " ++ show correct ++ "/" ++ show total_test_items
  
  where
    argmax :: ArrayF -> IO ArrayF
    argmax (NDArray ys) = NDArray . head <$> A.argmax (#data := ys .& #axis := Just 1 .& Nil)
